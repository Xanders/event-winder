require "spec"
require "../../src/event-winder"

EventWinder.register Basic
EventWinder.register Once, payload: Int32
EventWinder.register Unobserved, payload: Int32, max_pending: 1
EventWinder.register TupleValue, payload: {String, Int32}
EventWinder.register PayloadFailure, payload: Int32, max_pending: 1
EventWinder.register Bounded, payload: Int32, max_pending: 4
EventWinder.register Dropping, max_pending: 1, overflow: :drop
EventWinder.register Blocking, max_pending: 1, overflow: :block
EventWinder.register ImpossibleBlock, max_pending: 1, overflow: :block
EventWinder.register ImpossibleDrop, max_pending: 1, overflow: :drop
EventWinder.register Buffered, max_pending: 1
EventWinder.register Concurrent, max_pending: 3
EventWinder.register IndependentFirst, max_pending: 1
EventWinder.register IndependentSecond, max_pending: 1
EventWinder.register Recovering, payload: Bool, error_handler: -> { }, max_pending: 1
EventWinder.register RepeatedEmission, payload: Int32
EventWinder.register RepeatedDrop, payload: Int32, max_pending: 1, overflow: :drop

def fail_to_build_payload : Int32
  raise "payload failed"
end

Spec.after_each do
  EventWinder.drain(1.second).should be_true
  EventWinder.pending_handlings.should eq(0)
end

describe "production macro expansion" do
  it "handles events and captured variables with the default error handler" do
    variable = "initial"
    EventWinder.on Basic do
      variable = "handled"
    end
    EventWinder.emit(Basic).should be_true
    EventWinder.drain(1.second).should be_true
    variable.should eq("handled")
  end

  it "evaluates payload once synchronously and shares the value across handlers" do
    counter = 0
    values = [] of Int32
    2.times do
      EventWinder.on Once do |value|
        values << value
      end
    end
    EventWinder.emit(Once, counter += 1).should be_true
    counter.should eq(1)
    counter = 99
    EventWinder.drain(1.second).should be_true
    values.should eq([1, 1])
  end

  it "evaluates payload even when no handlers exist without reserving work" do
    counter = 0
    EventWinder.emit(Unobserved, counter += 1).should be_true
    counter.should eq(1)
    EventWinder.pending_handlings.should eq(0)
  end

  it "captures splatted tuples before the caller changes its variable" do
    values = [] of {String, Int32}
    EventWinder.on TupleValue do |name, value|
      values << {name, value}
    end
    tuple = {"original", 1}
    EventWinder.emit TupleValue, *tuple
    tuple = {"changed", 2}
    EventWinder.drain(1.second).should be_true
    values.should eq([{"original", 1}])
  end

  it "snapshots each payload when one emission callsite repeats in a while loop" do
    values = [] of Int32
    counter = Atomic(Int32).new(0)
    EventWinder.on RepeatedEmission do |value|
      values << value
    end
    index = 0
    while index < 10
      EventWinder.emit RepeatedEmission, counter.add(1)
      index += 1
    end
    EventWinder.drain(1.second).should be_true
    values.should eq((0...10).to_a)
  end

  it "never substitutes a dropped loop emission for an accepted payload" do
    values = [] of Int32
    accepted = [] of Bool
    counter = Atomic(Int32).new(0)
    EventWinder.on RepeatedDrop do |value|
      values << value
    end
    index = 0
    while index < 2
      accepted << EventWinder.emit(RepeatedDrop, counter.add(1))
      index += 1
    end
    accepted.should eq([true, false])
    EventWinder.drain(1.second).should be_true
    values.should eq([0])
  end

  it "propagates payload exceptions synchronously without leaking capacity or monitoring" do
    emitted = [] of String
    EventWinder.on EventWinder::Emitted do |name, time, count|
      emitted << name
    end
    values = [] of Int32
    EventWinder.on PayloadFailure do |value|
      values << value
    end
    expect_raises(Exception, "payload failed") do
      EventWinder.emit PayloadFailure, fail_to_build_payload
    end
    EventWinder.pending_handlings.should eq(0)
    emitted.should be_empty
    EventWinder.emit PayloadFailure, 7
    EventWinder.drain(1.second).should be_true
    values.should eq([7])
    emitted.should eq(["PayloadFailure"])
  end

  it "does not recursively monitor explicitly emitted monitoring events" do
    names = [] of String
    EventWinder.on EventWinder::Emitted do |name, time, count|
      names << name
    end
    EventWinder.emit EventWinder::Emitted, "manual", Time.utc, 0
    EventWinder.emit EventWinder::Handled, "manual", Time.utc, 0.seconds, 0.seconds, true
    EventWinder.drain(1.second).should be_true
    names.should eq(["manual"])
  end
end

describe "bounded pending handler calls" do
  it "raises at the boundary without partial fan-out and releases capacity after completion" do
    gate = Channel(Nil).new(6)
    values = [] of Int32
    2.times do
      EventWinder.on Bounded do |value|
        gate.receive
        values << value
      end
    end
    EventWinder.emit Bounded, 1
    EventWinder.emit Bounded, 2
    expect_raises(EventWinder::QueueFull) { EventWinder.emit Bounded, 3 }
    4.times { gate.send(nil) }
    EventWinder.drain(1.second).should be_true
    values.sort.should eq([1, 1, 2, 2])
    EventWinder.emit Bounded, 4
    2.times { gate.send(nil) }
    EventWinder.drain(1.second).should be_true
    values.sort.should eq([1, 1, 2, 2, 4, 4])
  end

  it "drops the whole new event and returns false without emitting monitoring for it" do
    emitted = [] of String
    EventWinder.on EventWinder::Emitted do |name, time, count|
      emitted << name if name == "Dropping"
    end
    gate = Channel(Nil).new(1)
    calls = 0
    EventWinder.on Dropping do
      gate.receive
      calls += 1
    end
    EventWinder.emit(Dropping).should be_true
    EventWinder.emit(Dropping).should be_false
    gate.send(nil)
    EventWinder.drain(1.second).should be_true
    calls.should eq(1)
    emitted.should eq(["Dropping"])
  end

  it "blocks the producer until the active handler frees capacity" do
    entered = Channel(Nil).new(2)
    gate = Channel(Nil).new
    accepted = Channel(Bool).new(1)
    EventWinder.on Blocking do
      entered.send(nil)
      gate.receive
    end
    EventWinder.emit Blocking
    entered.receive
    spawn { accepted.send(EventWinder.emit(Blocking)) }
    select
    when accepted.receive
      fail "Second emit was accepted while the first handler was still active"
    when timeout(10.milliseconds)
    end
    gate.send(nil)
    select
    when result = accepted.receive
      result.should be_true
    when timeout(1.second)
      fail "Blocked producer did not resume"
    end
    entered.receive
    gate.send(nil)
  end

  it "raises instead of blocking forever when a complete fan-out cannot fit" do
    2.times do
      EventWinder.on ImpossibleBlock do
      end
    end
    expect_raises(EventWinder::QueueFull) { EventWinder.emit ImpossibleBlock }
  end

  it "drops a fan-out larger than the limit without partial delivery" do
    calls = 0
    2.times do
      EventWinder.on ImpossibleDrop do
        calls += 1
      end
    end
    EventWinder.emit(ImpossibleDrop).should be_false
    EventWinder.drain(1.second).should be_true
    calls.should eq(0)
  end

  it "limits work even when the underlying channel has a larger buffer" do
    gate = Channel(Nil).new(1)
    EventWinder.on Buffered, capacity: 10 do
      gate.receive
    end
    EventWinder.emit Buffered
    expect_raises(EventWinder::QueueFull) { EventWinder.emit Buffered }
    gate.send(nil)
  end

  it "does not over-admit concurrent producers" do
    gate = Channel(Nil).new(3)
    results = Channel(Bool).new(20)
    EventWinder.on Concurrent do
      gate.receive
    end
    20.times do
      spawn do
        begin
          results.send(EventWinder.emit(Concurrent))
        rescue EventWinder::QueueFull
          results.send(false)
        end
      end
    end
    Array.new(20) { results.receive }.count(true).should eq(3)
    3.times { gate.send(nil) }
  end

  it "keeps limits independent between event types" do
    gate = Channel(Nil).new(2)
    EventWinder.on IndependentFirst do
      gate.receive
    end
    EventWinder.on IndependentSecond do
      gate.receive
    end
    EventWinder.emit IndependentFirst
    EventWinder.emit(IndependentSecond).should be_true
    expect_raises(EventWinder::QueueFull) { EventWinder.emit IndependentFirst }
    expect_raises(EventWinder::QueueFull) { EventWinder.emit IndependentSecond }
    2.times { gate.send(nil) }
  end

  it "releases capacity on rescued errors and resets monitoring success for the next call" do
    outcomes = [] of Bool
    EventWinder.on EventWinder::Handled do |name, time, queue, duration, success|
      outcomes << success if name == "Recovering"
    end
    EventWinder.on Recovering do |fail|
      raise "expected failure" if fail
    end
    EventWinder.emit Recovering, true
    EventWinder.drain(1.second).should be_true
    EventWinder.emit Recovering, false
    EventWinder.drain(1.second).should be_true
    outcomes.should eq([false, true])
  end

  it "validates limits and overflow policies" do
    expect_raises(ArgumentError, "max_pending must be positive") do
      EventWinder::PendingCounter.new("Invalid", 0)
    end
    expect_raises(ArgumentError, "max_pending must be positive") do
      EventWinder::PendingCounter.new("Invalid", -1)
    end
    expect_raises(ArgumentError, "overflow must be :raise, :block, or :drop") do
      EventWinder::PendingCounter.new("Invalid", 1, :unknown)
    end
  end
end
