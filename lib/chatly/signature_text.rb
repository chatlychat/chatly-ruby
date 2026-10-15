# frozen_string_literal: true

# Private helpers for `Chatly::Webhooks.verify_chatly_signature` — reading
# untrusted header text. Split out of `signatures.rb` to keep it under this
# repository's 650-line ceiling (`scripts/check-file-size.mjs`). Every method
# is total: none raises on any input, because the verifier may not.
module Chatly
  module Webhooks
    # JavaScript's String.prototype.trim set (WhiteSpace + LineTerminator).
    # Ruby's `strip` is NOT it: it strips NUL and leaves U+00A0, U+FEFF and
    # the U+2000 block in place, so `strip` would accept a digest with a NUL
    # appended that every other SDK refuses as malformed. A header value is
    # untrusted, and "close" is a divergence an attacker gets to choose.
    JS_WHITESPACE = "\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
    private_constant :JS_WHITESPACE

    # Bytes (the verifier reads header values with `.b`) are trimmed of the
    # ASCII members of that set only: a multi-byte space cannot be told apart
    # from part of a character without decoding, and no Chatly sender pads a
    # header with one. Text that is valid UTF-8 gets the whole set.
    def self.js_trim(text)
      return text unless text.is_a?(String)

      if text.encoding == Encoding::BINARY || !text.valid_encoding?
        return text.sub(/\A[\t\n\v\f\r ]+/n, "").sub(/[\t\n\v\f\r ]+\z/n, "")
      end

      text.sub(/\A[#{JS_WHITESPACE}]+/, "").sub(/[#{JS_WHITESPACE}]+\z/, "")
    rescue EncodingError, ArgumentError
      text
    end
    private_class_method :js_trim

    def self.utf8_bytes(text)
      return text.b if text.encoding == Encoding::BINARY

      text.encode(Encoding::UTF_8).b
    rescue EncodingError
      text.b
    end
    private_class_method :utf8_bytes

    # Every value of every key that matches `name` case-insensitively. So
    # `{"x-a" => v, "X-A" => w}` is TWO values, which is the point: a proxy
    # that added a differently cased copy has produced a duplicate, and the
    # duplicate check must see it. nil values are absent; non-Strings are
    # kept so they count, and are refused where they are read.
    def self.header_values(headers, name)
      return [] unless headers.respond_to?(:each_pair)

      wanted = name.downcase
      found = []
      headers.each_pair do |key, value|
        next unless (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.downcase == wanted
        next if value.nil?

        if value.is_a?(Array)
          found.concat(value.compact)
        else
          found << value
        end
      end
      found
    end
    private_class_method :header_values

    # Parse `t=...,v1=...[,b=...]`, collecting EVERY v1 (a sender mid-rotation
    # signs with both secrets) and keeping the FIRST t and the FIRST b, so an
    # appended field cannot move the window or the base. Unknown fields are
    # ignored, so a future `v3=` does not break a v1 verifier.
    def self.parse_tv1(raw)
      t = nil
      b = nil
      v1 = []
      raw.split(",", -1).each do |part|
        eq = part.index("=")
        next if eq.nil? || eq.zero?

        key = js_trim(part[0...eq])
        value = js_trim(part[(eq + 1)..].to_s)
        case key
        when "t" then t ||= value
        when "b" then b ||= value
        when "v1" then v1 << value
        end
      end
      return nil if t.nil? || v1.empty?

      { t: t, v1: v1, b: b }
    end
    private_class_method :parse_tv1

    # Non-empty String secrets, each with its index into what the CALLER
    # passed: `["", s]` verifying with `s` reports 1, not 0, because 0 would
    # name the wrong slot in the caller's own config.
    def self.secrets_from(secret)
      list = case secret
             when String then [secret]
             when Array then secret
             else []
             end
      list.each_with_index.select { |value, _| value.is_a?(String) && !value.empty? }
    end
    private_class_method :secrets_from

    def self.target?(input)
      method = input[:method]
      path = input[:path]
      method.is_a?(String) && !method.empty? && path.is_a?(String) && !path.empty?
    end
    private_class_method :target?

    def self.refuse(surface, reason, message)
      SignatureResult.new(ok: false, surface: surface, reason: reason, message: message).freeze
    end
    private_class_method :refuse

    def self.real_number?(value)
      value.is_a?(Numeric) && !(value.is_a?(Float) && value.nan?)
    end
    private_class_method :real_number?

    def self.capitalise(text)
      text.empty? ? text : text[0].upcase + text[1..]
    end
    private_class_method :capitalise

    # Clip an untrusted header value so an error message stays one line.
    # Scrubbed, because the value may be bytes that are not UTF-8 and
    # interpolating those into a UTF-8 message raises.
    def self.preview(text)
      text = text.dup.force_encoding(Encoding::UTF_8).scrub("?")
      text.length > 48 ? "#{text[0, 47]}..." : text
    end
    private_class_method :preview
  end
end
