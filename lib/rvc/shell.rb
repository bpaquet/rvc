# Copyright (c) 2011 VMware, Inc.  All Rights Reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

module RVC

class Shell
  attr_reader :fs, :connections, :session, :raise_exception_on_task_error
  attr_accessor :debug

  def initialize session, raise_exception_on_task_error = false
    @session = session
    @persist_ruby = false
    @fs = RVC::FS.new RVC::RootNode.new
    @ruby_evaluator = RubyEvaluator.new @fs
    @connections = {}
    @debug = false
    @raise_exception_on_task_error = raise_exception_on_task_error
  end

  def eval_input input
    if input == '//'
      @persist_ruby = !@persist_ruby
      return false
    end

    if input[0..0] == '!'
      RVC::Util.system_fg input[1..-1]
      return false
    end

    ruby = @persist_ruby
    if input =~ /^\//
      input = $'
      ruby = !ruby
    end

    begin
      if ruby
        eval_ruby input
      else
        eval_command input
      end
    rescue SystemExit, IOError
      raise
    rescue RVC::Util::UserError, RuntimeError, RbVmomi::Fault
      if ruby or debug
        puts "#{$!.class}: #{$!.message}"
        puts $!.backtrace * "\n"
      else
        case $!
        when RbVmomi::Fault, RVC::Util::UserError
          puts $!.message
        else
          puts "#{$!.class}: #{$!.message}"
        end
      end
      return false
    rescue Exception
      puts "#{$!.class}: #{$!.message}"
      puts $!.backtrace * "\n"
      return false
    end
    return true
  end

  def eval_command input
    cmd, *args = Shellwords.shellwords(input)
    return unless cmd
    RVC::Util.err "invalid command" unless cmd.is_a? String
    case cmd
    when RVC::FS::MARK_PATTERN
      CMD.basic.cd RVC::Util.lookup_single(cmd)
    else
      if cmd.include? '.'
        module_name, cmd, = cmd.split '.'
      elsif ALIASES.member? cmd
        module_name, cmd, = ALIASES[cmd].split '.'
      else
        RVC::Util.err "unknown alias #{cmd}"
      end

      m = MODULES[module_name] or RVC::Util.err("unknown module #{module_name}")

      opts_block = m.opts_for(cmd.to_sym)
      parser = RVC::OptionParser.new cmd, &opts_block

      begin
        args, opts = parser.parse args
      rescue Trollop::HelpNeeded
        parser.educate
        return
      end

      if parser.has_options?
        m.send cmd.to_sym, *(args + [opts])
      else
        m.send cmd.to_sym, *args
      end
    end
    nil
  end

  def eval_ruby input, file="<input>"
    result = @ruby_evaluator.do_eval input, file
    if $interactive
      if input =~ /\#$/
        introspect_object result
      else
        pp result
      end
    end
  end

  def prompt
    if false
      "#{@fs.display_path}#{$terminal.color(@persist_ruby ? '~' : '>', :yellow)} "
    else
      "#{@fs.display_path}#{@persist_ruby ? '~' : '>'} "
    end
  end

  def introspect_object obj
    case obj
    when RbVmomi::VIM::DataObject, RbVmomi::VIM::ManagedObject
      introspect_class obj.class
    when Array
      klasses = obj.map(&:class).uniq
      if klasses.size == 0
        puts "Array"
      elsif klasses.size == 1
        $stdout.write "Array of "
        introspect_class klasses[0]
      else
        counts = Hash.new 0
        obj.each { |o| counts[o.class] += 1 }
        puts "Array of:"
        counts.each { |k,c| puts "  #{k}: #{c}" }
        puts
        $stdout.write "Common ancestor: "
        introspect_class klasses.map(&:ancestors).inject(&:&)[0]
      end
    else
      puts obj.class
    end
  end

  def introspect_class klass
    q = lambda { |x| x =~ /^xsd:/ ? $' : x }
    if klass < RbVmomi::VIM::DataObject
      puts "Data Object #{klass}"
      klass.full_props_desc.each do |desc|
        puts " #{desc['name']}: #{q[desc['wsdl_type']]}#{desc['is-array'] ? '[]' : ''}"
      end
    elsif klass < RbVmomi::VIM::ManagedObject
      puts "Managed Object #{klass}"
      puts
      puts "Properties:"
      klass.full_props_desc.each do |desc|
        puts " #{desc['name']}: #{q[desc['wsdl_type']]}#{desc['is-array'] ? '[]' : ''}"
      end
      puts
      puts "Methods:"
      klass.full_methods_desc.sort_by(&:first).each do |name,desc|
        params = desc['params']
        puts " #{name}(#{params.map { |x| "#{x['name']} : #{q[x['wsdl_type'] || 'void']}#{x['is-array'] ? '[]' : ''}" } * ', '}) : #{q[desc['result']['wsdl_type'] || 'void']}"
      end
    else
      puts klass
    end
  end

  def delete_numeric_marks
    @session.marks.grep(/^\d+$/).each { |x| @session.set_mark x, nil }
  end
end

class RubyEvaluator
  include RVC::Util

  def initialize fs
    @binding = toplevel
    @fs = fs
  end

  def toplevel
    binding
  end

  def do_eval input, file
    begin
      eval input, @binding, file
    rescue Exception => e
      bt = e.backtrace
      bt = bt.reverse.drop_while { |x| !(x =~ /toplevel/) }.reverse
      bt[-1].gsub! ':in `toplevel\'', ''
      e.set_backtrace bt
      raise
    end
  end

  def this
    @fs.cur
  end

  def dc
    @fs.lookup("~").first
  end

  def conn
    @fs.lookup("~@").first
  end

  def method_missing sym, *a
    super unless $shell
    str = sym.to_s
    if a.empty?
      if MODULES.member? str
        MODULES[str]
      elsif str =~ /_?([\w\d]+)(!?)/ && objs = $shell.session.get_mark($1)
        if $2 == '!'
          objs
        else
          objs.first
        end
      else
        super
      end
    else
      super
    end
  end
end

end
