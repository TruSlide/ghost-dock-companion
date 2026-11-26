// Test hook: swift tools/mood.swift calm|call|burning|needs|live
import Foundation
let m = CommandLine.arguments.dropFirst().first ?? "live"
DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.ghostshell.mood"), object: m, userInfo: nil, deliverImmediately: true)
