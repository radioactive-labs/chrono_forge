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

  class Repeat
    def perform
      durably_repeat :tick, every: 1.second, till: :done?
    end
  end

  class Traced
    def perform
      setup
      durably_execute :finish
    end

    private

    def setup
      durably_execute :charge
    end
  end

  class Loopy
    def perform
      orders.each { |o| durably_execute :ship }
    end
  end

  # C1: unless body runs when predicate is FALSE; else when TRUE.
  class Unless
    def perform
      unless vip?
        durably_execute :a
      else
        durably_execute :b
      end
    end
  end

  # C2: outer guard composes with inner guard.
  class Nested
    def perform
      if x?
        if y?
          durably_execute :a
        end
      end
    end
  end

  # C2: elsif/else compose the negated outer predicate(s).
  class Elsif
    def perform
      if x?
        durably_execute :a
      elsif y?
        durably_execute :c
      else
        durably_execute :d
      end
    end
  end

  # C3: two classes in the same file with a same-named helper. Each perform must
  # trace its OWN class's #shared, not the last-parsed one.
  class FirstWf
    def perform
      shared
    end

    private

    def shared
      durably_execute :first_impl
    end
  end

  class SecondWf
    def perform
      shared
    end

    private

    def shared
      durably_execute :second_impl
    end
  end

  # I1: a dynamic-named branch and dynamic-named merge are unrelated — no join.
  class DynMerge
    def perform
      branch(dyn) { spawn :x }
      merge_branches(other)
    end
  end

  # M3: a multiline predicate must collapse to a single-line guard label.
  class Multiline
    def perform
      if (a? &&
          b?)
        durably_execute :m
      end
    end
  end

  # I2: durable calls inside begin/rescue must not be dropped.
  class Begins
    def perform
      begin
        durably_execute :risky
      rescue
        durably_execute :fallback
      end
    end
  end
end
