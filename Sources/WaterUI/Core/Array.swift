//
//  Array.swift
//  waterui-swift
//
//  Created by Lexo Liu on 9/30/25.
//

import CWaterUI

// Helper class to store array information without generic parameters
private final class ArrayInfo {
  let baseAddress: UnsafeMutableRawPointer?
  let count: Int
  let elementSize: Int
  private let destroyStorage: (UnsafeMutableRawPointer?, Int) -> Void

  init(
    baseAddress: UnsafeMutableRawPointer?,
    count: Int,
    elementSize: Int,
    destroyStorage: @escaping (UnsafeMutableRawPointer?, Int) -> Void
  ) {
    self.baseAddress = baseAddress
    self.count = count
    self.elementSize = elementSize
    self.destroyStorage = destroyStorage
  }

  func destroy() {
    destroyStorage(baseAddress, count)
  }
}

private let wuiArrayDropFunction: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
  guard let ptr else { return }
  let box = Unmanaged<AnyObject>.fromOpaque(ptr).takeRetainedValue()
  guard let arrayInfo = box as? ArrayInfo else {
    fatalError("WaterUI FFI array drop received an invalid ArrayInfo object")
  }
  arrayInfo.destroy()
}

private let wuiArraySliceFunction: @convention(c) (UnsafeRawPointer?) -> WuiArraySlice = { ptr in
  guard let ptr else {
    fatalError("WaterUI FFI array slice received a null ArrayInfo pointer")
  }

  let box = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
  guard let arrayInfo = box as? ArrayInfo else {
    fatalError("WaterUI FFI array slice received an invalid ArrayInfo object")
  }

  return WuiArraySlice(
    head: arrayInfo.baseAddress,
    len: UInt(arrayInfo.count)
  )
}

final class WuiRawArray {
  private var inner: CWaterUI.WuiArray?

  init(_ inner: CWaterUI.WuiArray) {
    self.inner = inner
  }

  func intoInner() -> CWaterUI.WuiArray {
    let v = inner!
    inner = nil
    return v
  }

  init<T>(array: [T]) {
    let baseAddress: UnsafeMutableRawPointer?
    if array.isEmpty {
      baseAddress = nil
    } else {
      let typedPointer = UnsafeMutablePointer<T>.allocate(capacity: array.count)
      typedPointer.initialize(from: array, count: array.count)
      baseAddress = UnsafeMutableRawPointer(typedPointer)
    }

    let vtable = WuiArrayVTable(drop: wuiArrayDropFunction, slice: wuiArraySliceFunction)
    let arrayInfo = ArrayInfo(
      baseAddress: baseAddress,
      count: array.count,
      elementSize: MemoryLayout<T>.size,
      destroyStorage: { rawPointer, count in
        guard let rawPointer else { return }
        let typedPointer = rawPointer.assumingMemoryBound(to: T.self)
        typedPointer.deinitialize(count: count)
        typedPointer.deallocate()
      }
    )
    let ptr = Unmanaged.passRetained(arrayInfo as AnyObject).toOpaque()
    let innerArray = CWaterUI.WuiArray(data: ptr, vtable: vtable)

    self.inner = innerArray
  }

  func toArray<T>() -> [T] {
    let slice = (inner!.vtable.slice)(inner!.data)
    let len = Int(slice.len)
    guard len > 0, let head = slice.head else {
      return []
    }

    let typedHead = head.assumingMemoryBound(to: T.self)
    let buffer = UnsafeBufferPointer<T>(start: typedHead, count: len)
    return Array(buffer)
  }

  func withUnsafeBufferPointer<T, R>(_ body: (UnsafeBufferPointer<T>) -> R) -> R {
    let slice = (inner!.vtable.slice)(inner!.data)
    let len = Int(slice.len)
    guard len > 0, let head = slice.head else {
      return body(UnsafeBufferPointer(start: nil, count: 0))
    }

    let typedHead = head.assumingMemoryBound(to: T.self)
    let buffer = UnsafeBufferPointer<T>(start: typedHead, count: len)
    return body(buffer)
  }

  @MainActor deinit {
    if let inner = inner {
      inner.vtable.drop(inner.data)
    }
  }
}

struct WuiArray<T> {
  var inner: WuiRawArray

  init(raw: WuiRawArray) {
    self.inner = raw
  }

  init(c: CWaterUI.WuiArray) {
    self.inner = .init(c)
  }

  init(array: [T]) {
    self.inner = .init(array: array)
  }

  func intoInner() -> CWaterUI.WuiArray {
    self.inner.intoInner()
  }

  func toArray() -> [T] {
    self.inner.toArray()
  }

  func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<T>) -> R) -> R {
    self.inner.withUnsafeBufferPointer(body)
  }
}

extension WuiArray<UInt8> {
  init(_ inner: CWaterUI.WuiArray_u8) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray where T == CWaterUI.WuiId {
  init(_ inner: CWaterUI.WuiArray_WuiId) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray where T == CWaterUI.WuiDate {
  init(_ inner: CWaterUI.WuiArray_WuiDate) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }

  func intoWuiDateArray() -> CWaterUI.WuiArray_WuiDate {
    unsafeBitCast(inner.intoInner(), to: CWaterUI.WuiArray_WuiDate.self)
  }
}

extension WuiArray where T == CWaterUI.WuiResolvedGradientStop {
  init(_ inner: CWaterUI.WuiArray_WuiResolvedGradientStop) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray<OpaquePointer> {
  init(_ inner: CWaterUI.WuiArray_____WuiAnyView) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray where T == CWaterUI.WuiHorizontalGuide {
  init(_ inner: CWaterUI.WuiArray_WuiHorizontalGuide) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray where T == CWaterUI.WuiVerticalGuide {
  init(_ inner: CWaterUI.WuiArray_WuiVerticalGuide) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray<CWaterUI.WuiStyledChunk> {
  init(_ inner: CWaterUI.WuiArray_WuiStyledChunk) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray<CWaterUI.WuiNavigationView> {
  init(_ inner: CWaterUI.WuiArray_WuiNavigationView) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray<CWaterUI.WuiNavigationToolbarItem> {
  init(_ inner: CWaterUI.WuiArray_WuiNavigationToolbarItem) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

extension WuiArray<CWaterUI.WuiTab> {
  init(_ inner: CWaterUI.WuiArray_WuiTab) {
    let raw = unsafeBitCast(inner, to: CWaterUI.WuiArray.self)
    self.init(c: raw)
  }
}

struct WuiStr {
  var inner: WuiArray<UInt8>

  init(_ inner: CWaterUI.WuiStr) {
    self.inner = WuiArray<UInt8>(inner._0)
  }

  init(string: String) {
    let bytes = [UInt8](string.utf8)
    self.inner = WuiArray<UInt8>(array: bytes)
  }

  func toString() -> String {
    inner.withUnsafeBufferPointer { bytes in
      String(decoding: bytes, as: UTF8.self)
    }
  }

  func intoInner() -> CWaterUI.WuiStr {
    unsafeBitCast(self.inner.intoInner(), to: CWaterUI.WuiStr.self)
  }

  func intoRustOwnedPointer() -> UnsafeMutablePointer<CWaterUI.WuiStr> {
    guard let pointer = waterui_str_box(intoInner()) else {
      fatalError("waterui_str_box returned null")
    }
    return pointer
  }
}
