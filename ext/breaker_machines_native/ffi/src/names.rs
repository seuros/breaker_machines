//! Symbol names for the core's enums. Every match is exhaustive: a new
//! variant fails to compile here until it has a name.
use breaker_machines::{
    Abandoned, Adopted, Completed, ForceClosed, Kind, Observed, Outcome, Refusal, Settled, State,
};
use magnus::{Ruby, Value, prelude::*};
use matryona_machines::ruby::{Symbols, symbol};

matryona_machines::symbols! {
    /// The core's refusals as Symbols: the snake case of each variant.
    pub Refusals for Refusal as "a refusal" {
        Open => "open",
        Busy => "busy",
        Full => "full",
        TimeRegression => "time_regression",
        Unknown => "unknown",
        Mismatch => "mismatch",
        Exhausted => "exhausted",
    }
}

matryona_machines::symbols! {
    /// The circuit's states.
    pub States for State as "a state" {
        Closed => "closed",
        Open => "open",
        HalfOpen => "half_open",
    }
}

matryona_machines::symbols! {
    /// What an operation did: `TypeError` for a non-Symbol, `RangeError`
    /// for another Symbol.
    pub Outcomes for Outcome as "outcome" {
        Success => "success",
        Failure => "failure",
    }
}

matryona_machines::symbols! {
    /// What a recorded outcome did.
    pub Settlements for Settled as "a settlement" {
        Counted => "counted",
        Opened => "opened",
        Closed => "closed",
    }
}

matryona_machines::symbols! {
    /// A ticket's kind.
    pub Kinds for Kind as "a kind" {
        Call => "call",
        Probe => "probe",
    }
}

const fn abandoned(answer: Abandoned) -> &'static str {
    match answer {
        Abandoned::Released => "released",
        Abandoned::Duplicate => "duplicate",
    }
}

const fn force_closed(answer: ForceClosed) -> &'static str {
    match answer {
        ForceClosed::Closed => "closed",
        ForceClosed::AlreadyClosed => "already_closed",
    }
}

fn completed(answer: Completed) -> &'static str {
    match answer {
        Completed::Settled(settled) => Settlements::name(settled),
        Completed::Duplicate(_) => "duplicate",
    }
}

const fn observed(answer: Observed) -> &'static str {
    match answer {
        Observed::Settled(Settled::Counted) => "counted",
        Observed::Settled(Settled::Opened) => "opened",
        Observed::Settled(Settled::Closed) => "closed",
        Observed::HalfOpened(Settled::Counted) => "half_opened",
        Observed::HalfOpened(Settled::Opened) => "half_opened_and_reopened",
        Observed::HalfOpened(Settled::Closed) => "half_opened_and_closed",
    }
}

const fn forced_open((): ()) -> &'static str {
    "opened"
}

fn answer<T>(ruby: &Ruby, outcome: Result<T, Refusal>, name: fn(T) -> &'static str) -> Value {
    let name = match outcome {
        Ok(honoured) => name(honoured),
        Err(refused) => Refusals::name(refused),
    };
    symbol(ruby, name).as_value()
}

pub fn refusal(ruby: &Ruby, refused: Refusal) -> Value {
    Refusals::symbol(ruby, refused).as_value()
}

pub fn completion(ruby: &Ruby, outcome: Result<Completed, Refusal>) -> Value {
    answer(ruby, outcome, completed)
}

pub fn abandonment(ruby: &Ruby, outcome: Result<Abandoned, Refusal>) -> Value {
    answer(ruby, outcome, abandoned)
}

pub fn observation(ruby: &Ruby, outcome: Result<Observed, Refusal>) -> Value {
    answer(ruby, outcome, observed)
}

pub fn opening(ruby: &Ruby, outcome: Result<(), Refusal>) -> Value {
    answer(ruby, outcome, forced_open)
}

matryona_machines::symbols! {
    /// What adopting a shared status did.
    pub Adoptions for Adopted as "an adoption" {
        Unchanged => "unchanged",
        Opened => "opened",
        Closed => "closed",
        HalfOpened => "half_opened",
    }
}

pub fn closing(ruby: &Ruby, outcome: Result<ForceClosed, Refusal>) -> Value {
    answer(ruby, outcome, force_closed)
}

pub fn adoption(ruby: &Ruby, outcome: Result<Adopted, Refusal>) -> Value {
    answer(ruby, outcome, Adoptions::name)
}
