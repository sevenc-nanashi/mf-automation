# frozen_string_literal: true

def decode_single_quote(encoded_str)
  result = +""
  i = 0
  while i < encoded_str.length
    if encoded_str[i] == "\\"
      if i + 1 < encoded_str.length && encoded_str[i + 1] == "'"
        result << "'"
        i += 2
      else
        result << encoded_str[i]
        i += 1
      end
    else
      result << encoded_str[i]
      i += 1
    end
  end
end
