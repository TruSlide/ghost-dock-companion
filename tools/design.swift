// Test hook: ask the running Ghost to design a shell (same path as the panel's box). swift tools/design.swift "a shell of autumn leaves"
import Foundation
let text = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.ghostshell.design"), object: text, userInfo: nil, deliverImmediately: true)
