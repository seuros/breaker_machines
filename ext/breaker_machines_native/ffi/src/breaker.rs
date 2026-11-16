//! `BreakerMachines::Breaker` and the tickets it issues.
use std::cell::RefCell;

use breaker_machines::{Admitted, Event, Settlement, Ticket as CoreTicket};
use magnus::{Error, Integer, RArray, Ruby, Symbol, Value, prelude::*, typed_data::Obj};
use matryona_machines::ruby::{
    Symbols, class_name, exact_typed_with, instant, integer, keep, nanoseconds, symbol,
};

use crate::classes::classes;
use crate::names::{self, Kinds, Outcomes, Settlements, States};
use crate::values;

/// Outcomes a breaker keeps, as the Rust runtime's circuit does.
const WINDOW: usize = 1000;

type Core = breaker_machines::Breaker<WINDOW>;

/// How a ticket was admitted, for `Ticket#admission`.
#[derive(Clone, Copy)]
enum Admission {
    Call,
    Probe,
    HalfOpened,
}

/// `BreakerMachines::Ticket`: the core's `Ticket`, built only by
/// `Breaker#admit`. It remembers how it was settled.
#[magnus::wrap(class = "BreakerMachines::Ticket", free_immediately, size)]
pub struct Ticket {
    ticket: RefCell<CoreTicket>,
    admission: Admission,
}

impl Ticket {
    fn id(&self) -> u64 {
        self.ticket.borrow().id()
    }

    fn kind(ruby: &Ruby, this: &Self) -> Symbol {
        Kinds::symbol(ruby, this.ticket.borrow().kind())
    }

    fn admission(ruby: &Ruby, this: &Self) -> Symbol {
        symbol(
            ruby,
            match this.admission {
                Admission::Call => "call",
                Admission::Probe => "probe",
                Admission::HalfOpened => "half_opened",
            },
        )
    }

    fn admitted_at(ruby: &Ruby, this: &Self) -> Integer {
        nanoseconds(ruby, this.ticket.borrow().admitted_at())
    }

    /// `nil` while unsettled, `:abandoned`, or `[outcome, settlement]`.
    fn settled(ruby: &Ruby, this: &Self) -> Value {
        let settled = this.ticket.borrow().settled();
        match settled {
            None => ruby.qnil().as_value(),
            Some(Settlement::Abandoned) => symbol(ruby, "abandoned").as_value(),
            Some(Settlement::Completed(outcome, settled)) => {
                let pair = ruby.ary_from_iter([
                    Outcomes::symbol(ruby, outcome),
                    Settlements::symbol(ruby, settled),
                ]);
                pair.freeze();
                pair.as_value()
            }
        }
    }
}

/// `value` when it is exactly a `BreakerMachines::Ticket` and not frozen.
fn ticket(ruby: &Ruby, value: Value) -> Result<Obj<Ticket>, Error> {
    let class = classes(ruby)?.ticket.get(ruby);
    let ticket = exact_typed_with::<Ticket>(ruby, value, class, || {
        format!(
            "ticket must be a BreakerMachines::Ticket, not {}",
            class_name(value)
        )
    })?;
    ticket.check_frozen()?;
    Ok(ticket)
}

#[magnus::wrap(class = "BreakerMachines::Breaker", free_immediately, size)]
pub struct Breaker {
    core: RefCell<Core>,
}

impl Breaker {
    pub fn new(ruby: &Ruby, policy: Value) -> Result<Self, Error> {
        let policy = values::policy(ruby, policy)?;
        Ok(Self {
            core: RefCell::new(Core::new(policy)),
        })
    }

    pub fn with_scope(ruby: &Ruby, policy: Value, scope: Value) -> Result<Self, Error> {
        let policy = values::policy(ruby, policy)?;
        let scope = integer(scope, "scope")?;
        Ok(Self {
            core: RefCell::new(Core::with_scope(policy, scope)),
        })
    }

    pub fn admit(ruby: &Ruby, this: Obj<Self>, now: Value) -> Result<Value, Error> {
        this.check_frozen()?;
        let now = instant(now, "now")?;
        // Resolved before the core issues a ticket: a failure here must not
        // leave an admission behind that Ruby never received.
        let class = classes(ruby)?.ticket.get(ruby);
        keep(
            ruby,
            this,
            &this.core,
            |core| core.admit(now),
            |admitted| {
                let (ticket, admission) = match admitted {
                    Ok(Admitted::Call(ticket)) => (ticket, Admission::Call),
                    Ok(Admitted::Probe(ticket)) => (ticket, Admission::Probe),
                    Ok(Admitted::HalfOpened(ticket)) => (ticket, Admission::HalfOpened),
                    Err(refusal) => return Ok(names::refusal(ruby, refusal)),
                };
                let ticket = Ticket {
                    ticket: RefCell::new(ticket),
                    admission,
                };
                Ok(ruby.obj_wrap_as(ticket, class).as_value())
            },
        )
    }

    pub fn complete(
        ruby: &Ruby,
        this: Obj<Self>,
        held: Value,
        outcome: Value,
        now: Value,
        draw: Value,
    ) -> Result<Value, Error> {
        this.check_frozen()?;
        let held = ticket(ruby, held)?;
        let outcome = Outcomes::parse(ruby, outcome)?;
        let (now, draw) = (instant(now, "now")?, integer(draw, "draw")?);
        let answer = {
            let mut core = this.core.borrow_mut();
            let mut ticket = held.ticket.borrow_mut();
            core.complete(&mut ticket, outcome, now, draw)
        };
        Ok(names::completion(ruby, answer))
    }

    pub fn abandon(ruby: &Ruby, this: Obj<Self>, held: Value) -> Result<Value, Error> {
        this.check_frozen()?;
        let held = ticket(ruby, held)?;
        let answer = {
            let mut core = this.core.borrow_mut();
            let mut ticket = held.ticket.borrow_mut();
            core.abandon(&mut ticket)
        };
        Ok(names::abandonment(ruby, answer))
    }

    pub fn observe(
        ruby: &Ruby,
        this: Obj<Self>,
        outcome: Value,
        took: Value,
        now: Value,
        draw: Value,
    ) -> Result<Value, Error> {
        this.check_frozen()?;
        let outcome = Outcomes::parse(ruby, outcome)?;
        let (took, now) = (instant(took, "took")?, instant(now, "now")?);
        let draw = integer(draw, "draw")?;
        let answer = this.core.borrow_mut().observe(outcome, took, now, draw);
        Ok(names::observation(ruby, answer))
    }

    pub fn force_open(
        ruby: &Ruby,
        this: Obj<Self>,
        now: Value,
        draw: Value,
    ) -> Result<Value, Error> {
        this.check_frozen()?;
        let (now, draw) = (instant(now, "now")?, integer(draw, "draw")?);
        let answer = this.core.borrow_mut().force_open(now, draw);
        Ok(names::opening(ruby, answer))
    }

    pub fn force_close(ruby: &Ruby, this: Obj<Self>) -> Result<Value, Error> {
        this.check_frozen()?;
        let answer = this.core.borrow_mut().force_close();
        Ok(names::closing(ruby, answer))
    }

    /// `nil`, or `:exhausted` when no transition epoch is left.
    pub fn reset(ruby: &Ruby, this: Obj<Self>) -> Result<Option<Value>, Error> {
        this.check_frozen()?;
        let answer = this.core.borrow_mut().reset();
        Ok(answer.err().map(|refused| names::refusal(ruby, refused)))
    }

    pub fn status(ruby: &Ruby, this: &Self) -> Result<Value, Error> {
        let status = this.core.borrow().status();
        values::status_object(ruby, status)
    }

    pub fn adopt(ruby: &Ruby, this: Obj<Self>, status: Value) -> Result<Value, Error> {
        this.check_frozen()?;
        let status = values::status(ruby, status)?;
        let answer = this.core.borrow_mut().adopt(status);
        Ok(names::adoption(ruby, answer))
    }

    pub fn state(ruby: &Ruby, this: &Self) -> Symbol {
        States::symbol(ruby, this.core.borrow().state())
    }

    pub fn policy(ruby: &Ruby, this: &Self) -> Result<Value, Error> {
        let policy = this.core.borrow().policy();
        values::policy_object(ruby, policy)
    }

    pub fn latest(ruby: &Ruby, this: &Self) -> Integer {
        nanoseconds(ruby, this.core.borrow().latest())
    }

    pub fn opened_at(ruby: &Ruby, this: &Self) -> Option<Integer> {
        let at = this.core.borrow().opened_at();
        at.map(|at| nanoseconds(ruby, at))
    }

    pub fn retry_at(ruby: &Ruby, this: &Self) -> Option<Integer> {
        let at = this.core.borrow().retry_at();
        at.map(|at| nanoseconds(ruby, at))
    }

    pub fn retry_after(ruby: &Ruby, this: &Self, now: Value) -> Result<Option<Integer>, Error> {
        let now = instant(now, "now")?;
        let after = this.core.borrow().retry_after(now);
        Ok(after.map(|after| nanoseconds(ruby, after)))
    }

    pub fn failures(&self, now: Value) -> Result<u32, Error> {
        let now = instant(now, "now")?;
        Ok(self.core.borrow().failures(now))
    }

    pub fn successes(&self, now: Value) -> Result<u32, Error> {
        let now = instant(now, "now")?;
        Ok(self.core.borrow().successes(now))
    }

    pub fn half_open_attempts(&self) -> u32 {
        self.core.borrow().half_open_attempts()
    }

    pub fn half_open_successes(&self) -> u32 {
        self.core.borrow().half_open_successes()
    }

    pub fn outstanding(&self) -> u32 {
        self.core.borrow().outstanding()
    }

    pub fn scope(&self) -> u16 {
        self.core.borrow().scope()
    }

    /// The newest `limit` outcomes, oldest first. Read into a Rust buffer
    /// under a short borrow, then built with no borrow held.
    pub fn events(ruby: &Ruby, this: &Self, limit: Value) -> Result<RArray, Error> {
        let limit = integer::<usize>(limit, "limit")?.min(WINDOW);
        let mut out = vec![Event::default(); limit];
        let n = this.core.borrow().events(&mut out);
        out.truncate(n);
        let events = ruby.ary_new_capa(n);
        for event in out {
            events.push(values::event_object(ruby, event)?)?;
        }
        Ok(events)
    }
}

impl Ticket {
    pub fn define(class: magnus::RClass) -> Result<(), Error> {
        use magnus::method;
        class.undef_default_alloc_func();
        class.define_method("id", method!(Ticket::id, 0))?;
        class.define_method("kind", method!(Ticket::kind, 0))?;
        class.define_method("admission", method!(Ticket::admission, 0))?;
        class.define_method("admitted_at", method!(Ticket::admitted_at, 0))?;
        class.define_method("settled", method!(Ticket::settled, 0))?;
        Ok(())
    }
}
