// Test hook: make the Ghost start an act now. swift tools/act.swift drift|zip|hover|scan|spin|peek|orbit|transmat|nap
import Foundation
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "drift"
DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.ghostshell.act"), object: name, userInfo: nil, deliverImmediately: true)
