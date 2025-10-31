# frozen_string_literal: true

class Date
  def beginning_of_month
    Date.new(year, month, 1)
  end
end

class Array
  def delete_if_first(&)
    index = self.index(&)
    index ? self.delete_at(index) : nil
  end
end
