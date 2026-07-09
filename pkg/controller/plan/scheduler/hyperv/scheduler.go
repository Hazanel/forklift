package hyperv

import (
	"context"
	"errors"
	"sync"

	api "github.com/kubev2v/forklift/pkg/apis/forklift/v1beta1"
	"github.com/kubev2v/forklift/pkg/apis/forklift/v1beta1/plan"
	plancontext "github.com/kubev2v/forklift/pkg/controller/plan/context"
	"github.com/kubev2v/forklift/pkg/controller/provider/web"
	model "github.com/kubev2v/forklift/pkg/controller/provider/web/hyperv"
	liberr "github.com/kubev2v/forklift/pkg/lib/error"
)

var mutex sync.Mutex

const Canceled = "Canceled"

// Scheduler for Hyper-V migrations.
// In cluster mode, tracks in-flight migrations per host (OwnerNode) so that
// no single node is overloaded. In standalone mode, all VMs share a single
// empty-string host key, preserving the original global-counter behavior.
type Scheduler struct {
	*plancontext.Context
	MaxInFlight int
	inFlight    map[string]int
	pending     map[string][]*plan.VMStatus
}

// Next returns the next VM to migrate.
func (r *Scheduler) Next() (vm *plan.VMStatus, hasNext bool, err error) {
	mutex.Lock()
	defer mutex.Unlock()

	err = r.buildSchedule()
	if err != nil {
		return
	}

	for host, vms := range r.pending {
		if r.inFlight[host] >= r.MaxInFlight {
			continue
		}
		if len(vms) > 0 {
			vm = vms[0]
			hasNext = true
			return
		}
	}
	return
}

func (r *Scheduler) buildSchedule() error {
	if err := r.buildInFlight(); err != nil {
		return err
	}
	r.buildPending()
	return nil
}

// buildInFlight counts running migrations grouped by host across all
// executing plans that share the same source provider.
func (r *Scheduler) buildInFlight() error {
	r.inFlight = make(map[string]int)

	for _, vmStatus := range r.Plan.Status.Migration.VMs {
		if vmStatus.HasCondition(Canceled) || !vmStatus.Running() {
			continue
		}
		r.inFlight[r.hostForVM(vmStatus)]++
	}

	planList := &api.PlanList{}
	if err := r.List(context.TODO(), planList); err != nil {
		return liberr.Wrap(err)
	}

	for _, p := range planList.Items {
		if p.Name == r.Plan.Name && p.Namespace == r.Plan.Namespace {
			continue
		}
		if p.Spec.Provider.Source != r.Plan.Spec.Provider.Source {
			continue
		}
		if p.Spec.Archived {
			continue
		}
		snapshot := p.Status.Migration.ActiveSnapshot()
		if !snapshot.HasCondition("Executing") {
			continue
		}
		for _, vmStatus := range p.Status.Migration.VMs {
			if vmStatus.Running() {
				r.inFlight[r.hostForVM(vmStatus)]++
			}
		}
	}
	return nil
}

// buildPending groups not-yet-started VMs by their host.
func (r *Scheduler) buildPending() {
	r.pending = make(map[string][]*plan.VMStatus)
	for _, vmStatus := range r.Plan.Status.Migration.VMs {
		if vmStatus.HasCondition(Canceled) {
			continue
		}
		if vmStatus.MarkedStarted() || vmStatus.MarkedCompleted() {
			continue
		}
		host := r.hostForVM(vmStatus)
		r.pending[host] = append(r.pending[host], vmStatus)
	}
}

// hostForVM resolves the host (OwnerNode) for a VM from inventory.
// In standalone mode or on lookup failure, returns "" which groups
// all VMs under a single key (global counter behavior).
func (r *Scheduler) hostForVM(vmStatus *plan.VMStatus) string {
	vm := &model.VM{}
	if err := r.Source.Inventory.Find(vm, vmStatus.Ref); err != nil {
		if !errors.As(err, &web.NotFoundError{}) {
			r.Log.V(1).Info(
				"Could not resolve host for VM, using global slot",
				"vm", vmStatus.String(),
				"error", err)
		}
		return ""
	}
	return vm.Host
}
