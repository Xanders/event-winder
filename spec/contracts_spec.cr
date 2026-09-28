require "./spec_helper"

describe "public API in a fresh process" do
  it "passes without the test-only global error handler or runtime macro errors" do
    output = IO::Memory.new
    status = Process.run("crystal", ["spec", "spec/programs/contracts.cr"],
      env: {"EVENT_WINDER_RUNTIME_ERRORS" => nil}, output: output, error: output)
    status.success?.should be_true, output.to_s
  end

  it "rejects invalid handler arguments at compile time" do
    output = IO::Memory.new
    status = Process.run("crystal", ["build", "--no-codegen", "spec/programs/invalid_handler.cr"],
      env: {"EVENT_WINDER_RUNTIME_ERRORS" => nil}, output: output, error: output)
    status.success?.should be_false
    output.to_s.should contain("handler should have 1 argument but 0 given")
  end

  it "releases the failed call when the default error handler terminates its fiber" do
    output = IO::Memory.new
    status = Process.run("crystal", ["run", "spec/programs/default_error.cr"],
      env: {"EVENT_WINDER_RUNTIME_ERRORS" => nil}, output: output, error: output)
    status.success?.should be_true, output.to_s
    output.to_s.should contain("default handler failure")
    output.to_s.should contain("pending=0")
  end
end
