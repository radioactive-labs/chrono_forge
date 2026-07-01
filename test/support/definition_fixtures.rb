# Fixture workflow classes for DefinitionAnalyzer. Only their SOURCE is read
# (Prism); they are never executed, so the bodies can reference helpers freely.
module DefinitionFixtures
  class Linear
    def perform
      context["started"] = true
      durably_execute :charge_card
      wait_until :funds_cleared
      wait :cooloff
      continue_if :approved
      durably_execute :ship, name: "ship_it"
      merge_branches :b, :a
    end
  end

  class Conditional
    def perform
      durably_execute :charge
      if vip?
        durably_execute :gift
      end
      continue_if :approved
      durably_execute :ship
    end
  end

  class FanOut
    def perform
      branch :ship do
        spawn_each :pkg, orders
      end
      merge_branches :ship
    end
  end
end
