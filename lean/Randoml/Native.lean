namespace Randoml.Native

/-- Opaque native entropy handle. Its C finalizer closes explicit source files. -/
opaque EntropySource : Type

@[extern "randoml_source_open"]
opaque sourceOpen (path : @& ByteArray) (noWait : Bool) : IO EntropySource

@[extern "randoml_source_fill"]
opaque sourceFill (source : @& EntropySource) (count : USize) : IO ByteArray

@[extern "randoml_platform_name"]
opaque platformName : BaseIO String

@[extern "randoml_architecture_name"]
opaque architectureName : BaseIO String

/-- Terminal-transport codec implemented at the byte-oriented native edge. -/
@[extern "randoml_base64"]
opaque base64 (bytes : @& ByteArray) : ByteArray

end Randoml.Native
