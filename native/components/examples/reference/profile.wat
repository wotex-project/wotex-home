;; Independent one-shot Canonical ABI test fixture, not a general allocator.
(module
  (type (;0;) (func (param i32 i32) (result i32)))
  (type (;1;) (func (param i32)))
  (type (;2;) (func (param i32) (result i32)))
  (type (;3;) (func (param i32 i32 i32 i32) (result i32)))
  (type (;4;) (func))
  (memory (;0;) 1)
  (export "cm32p2|wotex:home-profile/light-power@0.1|decode-power" (func 0))
  (export "cm32p2|wotex:home-profile/light-power@0.1|decode-power_post" (func 1))
  (export "cm32p2|wotex:home-profile/light-power@0.1|encode-power" (func 2))
  (export "cm32p2|wotex:home-profile/light-power@0.1|encode-power_post" (func 3))
  (export "cm32p2_memory" (memory 0))
  (export "cm32p2_realloc" (func 4))
  (export "cm32p2_initialize" (func 5))
  (func (;0;) (type 0) (param i32 i32) (result i32)
    (local $power i32)
    i32.const 256 i32.const 1 i32.store8
    i32.const 257 i32.const 0 i32.store8
    local.get 1 i32.const 2 i32.eq
    if
      local.get 0 i32.load16_u local.set $power
      local.get $power i32.eqz
      local.get $power i32.const 65535 i32.eq
      i32.or
      if
        i32.const 256 i32.const 0 i32.store8
        i32.const 257 local.get $power i32.const 65535 i32.eq i32.store8
      else
        i32.const 257 i32.const 1 i32.store8
      end
    end
    i32.const 256
  )
  (func (;1;) (type 1) (param i32))
  (func (;2;) (type 2) (param i32) (result i32)
    i32.const 272
    local.get 0
    if (result i32) i32.const 65535 else i32.const 0 end
    i32.store16
    i32.const 274 i32.const 0 i32.store
    i32.const 256 i32.const 272 i32.store
    i32.const 260 i32.const 6 i32.store
    i32.const 256
  )
  (func (;3;) (type 1) (param i32))
  (func (;4;) (type 3) (param i32 i32 i32 i32) (result i32)
    local.get 3 i32.const 4096 i32.gt_u
    if unreachable end
    i32.const 1024
  )
  (func (;5;) (type 4))
)
