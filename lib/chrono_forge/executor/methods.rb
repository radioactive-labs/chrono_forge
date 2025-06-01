module ChronoForge
  module Executor
    module Methods
      include Methods::Wait
      include Methods::WaitUntil
      include Methods::ContinueIf
      include Methods::DurablyExecute
      include Methods::DurablyRepeat
      include Methods::WorkflowStates
    end
  end
end
