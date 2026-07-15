import Darwin
import Foundation

final class AccountLoginOutputReader: @unchecked Sendable {
  private let pipe: Pipe
  private let handler: AccountLoginOutputHandler
  private let readLock = NSLock()
  private let deliveryLock = NSLock()
  private var deliveryTask: Task<Void, Never>?

  init(pipe: Pipe, handler: @escaping AccountLoginOutputHandler) {
    self.pipe = pipe
    self.handler = handler
  }

  func start() {
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 {
      _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      readLock.withLock {
        if !drainAvailableData(from: handle) {
          handle.readabilityHandler = nil
        }
      }
    }
  }

  func finish() async {
    pipe.fileHandleForReading.readabilityHandler = nil
    readLock.withLock {
      _ = drainAvailableData(from: pipe.fileHandleForReading)
    }
    let finalDelivery = deliveryLock.withLock { deliveryTask }
    await finalDelivery?.value
    try? pipe.fileHandleForReading.close()
  }

  func cancel() {
    pipe.fileHandleForReading.readabilityHandler = nil
    deliveryLock.withLock { deliveryTask?.cancel() }
    try? pipe.fileHandleForReading.close()
    try? pipe.fileHandleForWriting.close()
  }

  @discardableResult
  private func drainAvailableData(from handle: FileHandle) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(handle.fileDescriptor, &buffer, buffer.count)
      switch count {
      case let count where count > 0:
        enqueue(Data(buffer.prefix(count)))
      case 0:
        return false
      default:
        if errno == EAGAIN || errno == EWOULDBLOCK {
          return true
        }
        return false
      }
    }
  }

  private func enqueue(_ data: Data) {
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
    deliveryLock.withLock {
      let previous = deliveryTask
      deliveryTask = Task { [handler] in
        await previous?.value
        await handler(text)
      }
    }
  }
}
