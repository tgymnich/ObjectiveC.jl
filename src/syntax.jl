export @objc, @objcwrapper

callerror() = error("ObjectiveC call: use [obj method]::typ or [obj method :param::typ ...]::typ")

# convert a vcat to a hcat so that we can split the @objc expressions into multiple lines
function flatvcat(ex::Expr)
  any(ex->isexpr(ex, :row), ex.args) || return ex
  flat = Expr(:hcat)
  for row in ex.args
    isexpr(row, :row) ?
      push!(flat.args, row.args...) :
      push!(flat.args, row)
  end
  return flat
end

function objcm(ex)
    # handle a single call, [dst method: param::typ]::typ

    # parse the call return type
    Meta.isexpr(ex, :(::)) || callerror()
    call, rettyp = ex.args
    if Meta.isexpr(rettyp, :curly) && rettyp.args[1] == :id
        # we're returning an object pointer, with additional type info.
        # currently that info isn't used, so just strip it
        rettyp = rettyp.args[1]
    end

    # parse the call
    if Meta.isexpr(call, :vcat)
      call = flatvcat(call)
    end
    Meta.isexpr(call, :hcat) || return esc(call)
    obj, method, args... = call.args

    # argument should be typed expressions
    argnames, argvals, argtyps = [], [], []
    function parse_argument(arg; named=true)
        # name before the parameter (name:value::type) is optional
        if Meta.isexpr(arg, :call) && arg.args[1] == :(:)
          # form: name:value::typ
          name = String(arg.args[2])
          arg = arg.args[3]
        else
          name = nothing
        end
        push!(argnames, name)

        Meta.isexpr(arg, :(::)) || callerror()
        val, typ = arg.args
        if val isa QuoteNode
            # nameless params are parsed as a symbol
            # (there's an edge case when using e.g. `:length(x)::typ`, causing the `length`
            #  to be parsed as a symbol, but you should just use a param name in that case)
            val = val.value
        end
        if Meta.isexpr(typ, :curly) && typ.args[1] == :id
            # we're passing an object pointer, with additional type info.
            # currently that info isn't used, so just strip it
            typ = typ.args[1]
        end
        push!(argvals, val)
        push!(argtyps, typ)
    end

    # the method may be a plain symbol, or already contain the first arg
    if method isa Symbol
        argnames, argvals, argtyps = [], [], []
    elseif Meta.isexpr(method, :call) && method.args[1] == :(:)
        _, method, arg = method.args
        isa(method, Symbol) || callerror()
        parse_argument(arg)
    else
        callerror()
    end

    # deconstruct the remaining arguments
    for arg in args
        # first arg should always be part of the method
        isempty(argnames) && callerror()

        parse_argument(arg)
    end

    # the method should be a simple symbol. the resulting selector includes : for args
    method isa Symbol || callerror()
    sel = String(method) * join(map(name->something(name,"")*":", argnames))

    # the object should be a class (single symbol) or an instance (var + typeassert)
    ex = if obj isa Symbol
        # class
        class_message(obj, sel, rettyp, argtyps, argvals)
    elseif Meta.isexpr(obj, :(::))
        # instance
        val, typ = obj.args
        if val isa Expr
            # possibly dealing with a nested expression, so recurse
            quote
                obj = $(objcm(obj))
                $(instance_message(:obj, sel, rettyp, argtyps, argvals))
            end
        else
            instance_message(esc(val), sel, rettyp, argtyps, argvals)
        end
        # XXX: do something with the instance type?
    else
        callerror()
    end

    return ex
end

function class_message(class_name, msg, rettyp, argtyps, argvals)
    quote
        class = Class($(String(class_name)))
        sel = Selector($(String(msg)))
        ccall(:objc_msgSend, $(esc(rettyp)),
              (Ptr{Cvoid}, Ptr{Cvoid}, $(map(esc, argtyps)...)),
              class, sel, $(map(esc, argvals)...))
    end
end

function instance_message(instance, msg, rettyp, argtyps, argvals)
    quote
        sel = Selector($(String(msg)))
        ccall(:objc_msgSend, $(esc(rettyp)),
              (id, Ptr{Cvoid}, $(map(esc, argtyps)...)),
              $instance, sel, $(map(esc, argvals)...))
    end
end

macro objc(ex)
  objcm(ex)
end


# Wrapper Classes

wrappererror(msg) = error("""ObjectiveC wrapper: $msg
                             Use `@objcwrapper Class` or `Class <: SuperType`; see `?@objcwrapper` for more details.""")

"""
    @objcwrapper [kwargs] name [<: super]

Helper macro to define a Julia class named `name` for wrapping Objective C pointers. The
supertype of this class is `super`, which defaults to `Object`.

The generated class is a simple wrapper around an `id` pointer, along with the required
conversion methods that are expected by the `@objc` macro. Other methods can be generated
too, and are controlled by the optional keyword arguments:

  * `immutable`: if `true` (default), define the wrapper class as an immutable.
    Should be disabled when you want to use finalizers.
  * `comparison`: if `true` (default), define `==` and `hash` methods for the wrapper
    class. This is useful for using the wrapper class as a key in a dictionary.
    Should be disabled when using  a custom comparison method.
"""
macro objcwrapper(ex...)
  def = ex[end]
  kwargs = ex[1:end-1]

  # parse kwargs
  comparison = true
  immutable = true
  for kw in kwargs
    if kw isa Expr && kw.head == :(=)
      kw, val = kw.args
      if kw == :comparison
        val isa Bool || wrappererror("comparison keyword argument must be a literal boolean")
        comparison = val
      elseif kw == :immutable
        val isa Bool || wrappererror("immutable keyword argument must be a literal boolean")
        immutable = val
      else
        wrappererror("unrecognized keyword argument: $kw")
      end
    else
      wrappererror("invalid keyword argument: $kw")
    end
  end

  # parse class definition
  if Meta.isexpr(def, :(<:))
    name, super = def.args
  elseif def isa Symbol
    name = def
    super = Object
  else
    wrappererror()
  end

  # generate class definition
  ex = if immutable
    quote
      struct $name <: $super
        ptr::id

        # restrict the default constructor
        $name(ptr::id) = new(ptr)
      end
    end
  else
    quote
      mutable struct $name <: $super
        ptr::id

        # restrict the default constructor
        $name(ptr::id) = new(ptr)
      end
    end
  end
  append!(ex.args, (quote
    Base.unsafe_convert(::Type{id}, dev::$name) = dev.ptr
  end).args)

  # add optional methods
  if comparison
    append!(ex.args, (quote
      Base.:(==)(a::$name, b::$name) = a.ptr == b.ptr
      Base.hash(dev::$name, h::UInt) = hash(dev.ptr, h)
    end).args)
  end

  esc(ex)
end
