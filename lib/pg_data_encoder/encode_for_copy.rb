require 'tempfile'
require 'stringio'

module PgDataEncoder
  class EncodeForCopy
    def initialize(options = {})
      @options = options
      @closed = false
      options[:column_types] ||= {}
      @io = nil
      @buffer = TempBuffer.new
    end

    def add(row)
      setup_io unless @io
      @io.write([row.size].pack(PACKED_UINT_16))
      row.each_with_index do |col, index|
        encode_field(@buffer, col, index)
        next if @buffer.empty?
        @io.write(@buffer.read)
        @buffer.reopen
      end
    end

    def close
      @closed = true
      unless @buffer.empty?
        @io.write(@buffer.read)
        @buffer.reopen
      end
      @io.write([-1].pack(PACKED_UINT_16)) rescue raise Exception, 'No rows have been added to the encoder!'
      @io.rewind
    end

    def get_io
      close unless @closed
      @io
    end

    def remove
      return unless @io.is_a?(Tempfile)

      @io.close
      @io.unlink
    end

    private

    def setup_io
      if @options[:use_tempfile] == true
        @io = Tempfile.new('copy_binary', encoding: 'ascii-8bit')
        @io.unlink unless @options[:skip_unlink] == true
      else
        @io = StringIO.new
      end
      @io.write("PGCOPY\n\377\r\n\0")
      @io.write([0, 0].pack(PACKED_UINT_32 + PACKED_UINT_32))
    end

    def write_field(io, buf)
      io.write([buf.bytesize].pack(PACKED_UINT_32))
      io.write(buf)
    end

    def encode_field(io, field, index, depth = 0)
      # puts format('encode_field(%s, %s, %s, %s)', io.inspect, field.inspect, index.inspect, depth.inspect)
      case field
      when Integer
        buf = if @options[:column_types] && @options[:column_types][index] == :bigint
                [field].pack(PACKED_UINT_64)
              elsif @options[:column_types] && @options[:column_types][index] == :smallint
                [field].pack(PACKED_UINT_16)
              else
                [field].pack(PACKED_UINT_32)
              end
        write_field(io, buf)
      when Float
        if @options[:column_types] && @options[:column_types][index] == :decimal
          encode_numeric(io, field)
        else
          buf = [field].pack(PACKED_FLOAT_64)
          write_field(io, buf)
        end
      when true
        buf = [1].pack(PACKED_UINT_8)
        write_field(io, buf)
      when false
        buf = [0].pack(PACKED_UINT_8)
        write_field(io, buf)
      when nil
        io.write([-1].pack(PACKED_UINT_32))
      when String
        if @options[:column_types] && @options[:column_types][index] == :uuid
          buf = [field.delete('-')].pack(PACKED_HEX_STRING)
          write_field(io, buf)
        elsif @options[:column_types] && @options[:column_types][index] == :bigint
          buf = [field.to_i].pack(PACKED_UINT_64)
          write_field(io, buf)
        elsif @options[:column_types] && @options[:column_types][index] == :inet
          encode_ip_addr(io, IPAddr.new(field))
        elsif @options[:column_types] && @options[:column_types][index] == :binary
          write_field(io, field)
        else
          buf = field.encode(UTF_8_ENCODING)
          write_field(io, buf)
        end
      when Array
        if @options[:column_types] && @options[:column_types][index] == :json
          buf = field.to_json.encode(UTF_8_ENCODING)
          write_field(io, buf)
        elsif @options[:column_types] && @options[:column_types][index] == :jsonb
          encode_jsonb(io, field)
        else
          array_io = TempBuffer.new
          field.compact!
          completed = false
          case field[0]
          when String
            if @options[:column_types][index] == :uuid
              array_io.write([1].pack(PACKED_UINT_32)) # unknown
              array_io.write([0].pack(PACKED_UINT_32)) # unknown

              array_io.write([UUID_TYPE_OID].pack(PACKED_UINT_32))
              array_io.write([field.size].pack(PACKED_UINT_32))
              array_io.write([1].pack(PACKED_UINT_32)) # forcing single dimension array for now

              field.each do |val|
                buf = [val.delete('-')].pack(PACKED_HEX_STRING)
                write_field(array_io, buf)
              end
            else
              array_io.write([1].pack(PACKED_UINT_32))  # unknown
              array_io.write([0].pack(PACKED_UINT_32))  # unknown

              array_io.write([VARCHAR_TYPE_OID].pack(PACKED_UINT_32))
              array_io.write([field.size].pack(PACKED_UINT_32))
              array_io.write([1].pack(PACKED_UINT_32)) # forcing single dimension array for now

              field.each do |val|
                buf = val.to_s.encode(UTF_8_ENCODING)
                write_field(array_io, buf)
              end
            end
          when Integer
            array_io.write([1].pack(PACKED_UINT_32)) # unknown
            array_io.write([0].pack(PACKED_UINT_32)) # unknown

            array_io.write([INT_TYPE_OID].pack(PACKED_UINT_32))
            array_io.write([field.size].pack(PACKED_UINT_32))
            array_io.write([1].pack(PACKED_UINT_32))   # forcing single dimension array for now

            field.each do |val|
              buf = [val.to_i].pack(PACKED_UINT_32)
              write_field(array_io, buf)
            end
          when nil
            io.write([-1].pack(PACKED_UINT_32))
            completed = true
          else
            raise Exception, 'Arrays support int or string only'
          end

          unless completed
            io.write([array_io.pos].pack(PACKED_UINT_32))
            io.write(array_io.string)
          end
        end
      when Hash
        raise Exception, "Hash's can't contain hashes" if depth > 0
        if @options[:column_types] && @options[:column_types][index] == :json
          buf = field.to_json.encode(UTF_8_ENCODING)
          write_field(io, buf)
        elsif @options[:column_types] && @options[:column_types][index] == :jsonb
          encode_jsonb(io, field)
        else
          hash_io = TempBuffer.new

          hash_io.write([field.size].pack(PACKED_UINT_32))
          field.each_pair do |key, val|
            buf = key.to_s.encode(UTF_8_ENCODING)
            write_field(hash_io, buf)
            encode_field(hash_io, val.nil? ? val : val.to_s, index, depth + 1)
          end
          io.write([hash_io.pos].pack(PACKED_UINT_32)) # size of hstore data
          io.write(hash_io.string)
        end
      when Time
        buf = [(field.to_f * 1_000_000 - POSTGRES_EPOCH_TIME).to_i].pack(PACKED_UINT_64)
        write_field(io, buf)
      when Date
        buf = [(field - Date.new(2000, 1, 1)).to_i].pack(PACKED_UINT_32)
        write_field(io, buf)
      when IPAddr
        encode_ip_addr(io, field)
      else
        raise Exception, "Unsupported Format: #{field.class.name}"
      end
    end

    def encode_ip_addr(io, ip_addr)
      if ip_addr.ipv6?
        io.write([4 + 16].pack(PACKED_UINT_32)) # Field data size
        io.write([3].pack(PACKED_UINT_8)) # Family (PGSQL_AF_INET6)
        io.write([128].pack(PACKED_UINT_8)) # Bits
        io.write([0].pack(PACKED_UINT_8)) # Is CIDR? => No
        io.write([16].pack(PACKED_UINT_8)) # Address length in bytes
      else
        io.write([4 + 4].pack(PACKED_UINT_32)) # Field data size
        io.write([2].pack(PACKED_UINT_8)) # Family (PGSQL_AF_INET)
        io.write([32].pack(PACKED_UINT_8)) # Bits
        io.write([0].pack(PACKED_UINT_8)) # Is CIDR? => No
        io.write([4].pack(PACKED_UINT_8)) # Address length in bytes
      end
      io.write(ip_addr.hton)
    end

    def encode_jsonb(io, field)
      buf = field.to_json.encode(UTF_8_ENCODING)
      io.write([1 + buf.bytesize].pack(PACKED_UINT_32))
      io.write([1].pack(PACKED_UINT_8)) # JSONB format version 1
      io.write(buf)
    end

    NUMERIC_DEC_DIGITS = 4 # NBASE=10000
    def encode_numeric(io, field)
      float_str = field.to_s
      digits_base10 = float_str.scan(/\d/).map(&:to_i)
      weight_base10 = float_str.index('.')
      sign          = field < 0.0 ? 0x4000 : 0
      dscale        = digits_base10.size - weight_base10

      digits_before_decpoint = digits_base10[0..weight_base10].reverse.each_slice(NUMERIC_DEC_DIGITS).map { |d| d.reverse.map(&:to_s).join.to_i }.reverse
      digits_after_decpoint  = digits_base10[weight_base10..-1].each_slice(NUMERIC_DEC_DIGITS).map { |d| d.map(&:to_s).join.to_i }

      weight = digits_before_decpoint.size - 1
      digits = digits_before_decpoint + digits_after_decpoint

      io.write([2 * 4 + 2 * digits.size].pack(PACKED_UINT_32)) # Field data size
      io.write([digits.size].pack(PACKED_UINT_16)) # ndigits
      io.write([weight].pack(PACKED_UINT_16)) # weight
      io.write([sign].pack(PACKED_UINT_16)) # sign
      io.write([dscale].pack(PACKED_UINT_16)) # dscale

      digits.each { |d| io.write([d].pack(PACKED_UINT_16)) } # NumericDigits
    end
  end
end
