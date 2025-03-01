using ObjectiveC
using Test

using ObjectiveC

@testset "@objc macro" begin
    # class methods
    @objc [NSString new]::id{Object}
    data = "test"
    @objc [NSString stringWithUTF8String:data::Ptr{UInt8}]::id{Object}
    @objc [NSString stringWithUTF8String:"test"::Ptr{UInt8}]::id{Object}
    obj = @objc [NSString stringWithUTF8String:"test"::Ptr{UInt8}]::id{Object}

    # instance methods
    @objc [obj::id{Object} length]::UInt
    @objc [obj::id{Object} length]::UInt
    @test @objc [obj::id{Object} isEqualTo:obj::id{Object}]::Bool
    empty_str = @objc [NSString string]::id{Object}
    @objc [obj::id stringByReplacingOccurrencesOfString:empty_str::id{Object} withString:empty_str::id{Object}]::id{Object}
end

@objcwrapper TestNSString <: Object
@testset "@objc calls" begin
    data = "test"
    ptr = @objc [NSString stringWithUTF8String:data::Ptr{UInt8}]::id{TestNSString}
    @test ptr isa id{TestNSString}
    @test class(ptr) isa Class
    @test "length" in methods(ptr)
    @test 4 == @objc [ptr::id length]::Culong

    obj = TestNSString(ptr)
    @test Base.unsafe_convert(id, obj) == ptr
    @test_throws UndefRefError TestNSString(nil)
end

@testset "@objc blocks" begin
    # create a dummy class we'll register our blocks with
    # (no need to use @objcwrapper as we're not constructing an id{BlockWrapper})
    wrapper_class = ObjectiveC.createclass(:BlockWrapper, Class(:NSObject))
    ptr = @objc [BlockWrapper alloc]::id{Object}

    # use the same type signature for both methods
    types = (Cint, Object, Selector, Cint)
    typestr = ObjectiveC.encodetype(types...)

    @testset "simple" begin
        function addone(x::T) where T
            return x + one(T)
        end
        @assert sizeof(addone) == 0
        block = Foundation.@objcblock(addone, Cint, (Cint,))

        imp = ccall(:imp_implementationWithBlock, Ptr{Cvoid}, (id{Foundation.NSBlock},), block)
        @assert ccall(:class_addMethod, Bool,
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cchar}),
                    wrapper_class, sel"invoke_simple:", imp, typestr)

        # create a wrapper instance and call our block
        ret = @objc [ptr::id{Object} invoke_simple:41::Cint]::Cint
        @test ret == 42
    end

    @testset "closure" begin
        val = Cint(2)
        function addbox(x::T) where T
            return x + val
        end
        @assert sizeof(addbox) != 0
        block = @objcblock(addbox, Cint, (Cint,))

        imp = ccall(:imp_implementationWithBlock, Ptr{Cvoid}, (id{Foundation.NSBlock},), block)
        @assert ccall(:class_addMethod, Bool,
                        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cchar}),
                        wrapper_class, sel"invoke_closure:", imp, typestr)

        ret = @objc [ptr::id{Object} invoke_closure:40::Cint]::Cint
        @test ret == 42
    end

    @testset "async" begin
        val = Ref(0)
        cond = Base.AsyncCondition() do async_cond
            val[] += 1
            close(async_cond)
        end
        block = @objcasyncblock(cond)

        types = (Nothing, Object, Selector)
        typestr = ObjectiveC.encodetype(types...)

        imp = ccall(:imp_implementationWithBlock, Ptr{Cvoid}, (id{Foundation.NSBlock},), block)
        @assert ccall(:class_addMethod, Bool,
                      (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cchar}),
                       wrapper_class, sel"invoke_async_condition", imp, typestr)

        ret = @objc [ptr::id{Object} invoke_async_condition]::Nothing
        retry(; delays=[0, 0.1, 1]) do
            # XXX: is there another wait? `wait(cond)` doesn't seem to work on 1.6
            val[] == 1 || error("val[] = $(val[])")
        end()
    end
end

@testset "foundation" begin

using .Foundation

@testset "NSString" begin
    str = NSString()
    @test is_kind_of(str, Class("NSString"))
    @test class(str) isa Class
    @test length(str) == 0
    @test String(str) == ""

    str = NSString("test")
    @test length(str) == 4
    @test String(str) == "test"

    @test NSString() == NSString()
    @test "" == NSString()
    @test NSString() == ""

    @test NSString("foo") != NSString("bar")
    @test "foo" != NSString("bar")
    @test NSString("foo") != "bar"
end

@testset "NSHost" begin
    @test hostname() == gethostname()
end

@testset "NSBundle" begin
    load_framework("IOKit")
    @test_throws ErrorException load_framework("NonExistingFramework")
end

@testset "NSArray" begin
    str1 = NSString("Hello")
    str2 = NSString("World")
    arr1 = [str1, str2]
    arr2 = NSArray([str1, str2])
    @test length(arr2) == 2
    @test reinterpret(NSString, arr2[1]) == "Hello"
    @test reinterpret(NSString, arr2[2]) == "World"
    @test Vector{NSString}(arr2) == arr1
end

@testset "NSDictionary" begin
    str1 = NSString("Hello")
    str2 = NSString("World")
    dict1 = Dict(str1 => str2)
    dict2 = NSDictionary(dict1)
    @test length(dict2) == 1
    @test keys(dict2) == NSArray([str1])
    @test values(dict2) == NSArray([str2])
    @test reinterpret(NSString, dict2[str1]) == "World"
    @test_throws KeyError dict2[str2]
    @test Dict{NSString,NSString}(dict2) == dict1
end

@testset "NSError" begin
    err = NSError("NSPOSIXErrorDomain", 1)
    @test isempty(err.userInfo)
    @test contains(err.localizedFailureReason, "Operation not permitted")
end

@testset "NSValue" begin
    val1 = Ptr{Cvoid}(12345)
    val2 = NSValue(val1)
    @test val2.pointerValue == val1
    @test val2 == NSValue(val1)

    val3 = NSRange(1,2)
    val4 = NSValue(val3)
    @test val4.rangeValue == val3
    @test val4 != val2
end

@testset "NSRange" begin
    # test conversion from UnitRange
    val1 = UnitRange(2:20)
    val2 = NSValue(val1)
    @test first(val1) == first(val2.rangeValue)
    @test last(val1) == last(val2.rangeValue)
    @test length(val1) == length(val2.rangeValue)
end

@testset "NSNumber" begin
    @testset "bool" begin
        t = NSNumber(true)
        f = NSNumber(false)
        @test t == t
        @test t != f
        @test t.boolValue == true
        @test f.boolValue == false
    end

    @testset "int" begin
        i = NSNumber(123)
        j = NSNumber(456)
        @test i == i
        @test i != j
        @test i.intValue == 123
        @test j.intValue == 456
    end
end

@testset "NSURL" begin
    url = NSURL("https://julialang.org/downloads/")
    @test !url.isFileURL
    @test url.scheme == "https"
    @test url.host == "julialang.org"
    @test url.path == "/downloads"
    @test url == NSURL("https://julialang.org/downloads/")

    file = NSFileURL("/foo/bar/baz.qux")
    @test file.isFileURL
    @test file.path == "/foo/bar/baz.qux"
    @test file.lastPathComponent == "baz.qux"
    @test file.pathComponents == NSString["/", "foo", "bar", "baz.qux"]
    @test file != url
end

end

@testset "dispatch" begin

using .Dispatch

@testset "dispatch_data" begin
    arr = [1]
    GC.@preserve arr begin
        data = dispatch_data(pointer(arr), sizeof(arr))

        retain(data)
        release(data)

        @test sizeof(data) == sizeof(arr)

        release(data)
    end
end

end

@testset "tracing" begin
    ObjectiveC.enable_tracing(true)
    cmd = ```$(Base.julia_cmd()) --project=$(Base.active_project())
                                 --eval "using ObjectiveC, .Foundation; String(NSString())"```

    out = Pipe()
    err = Pipe()
    proc = run(pipeline(cmd, stdout=out, stderr=err), wait=false)
    close(out.in)
    close(err.in)
    wait(proc)
    out = read(out, String)
    err = read(err, String)

    @test success(proc)
    @test isempty(out)
    @test contains(err, "+ [NSString string]")
    @test contains(err, r"- \[.+ UTF8String\]")
end
