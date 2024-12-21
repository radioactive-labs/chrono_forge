module ChronoForge
  module Executor
    module Methods
      include Methods::Wait
      include Methods::WaitUntil
      include Methods::DurablyExecute
    end
  end
end
