// What the Ghost can see on screen: the focused text box (to keep out of it), elements of the front window (to scan),
// and how many points make an inch. Uses the macOS Accessibility API, read-only; it never reads text or values.
// Without the Accessibility permission it falls back to window frames only (no text-box avoidance).

import AppKit
import ApplicationServices

enum Sense {
    /// True when the user has allowed Ghost in System Settings › Privacy & Security › Accessibility.
    static func trusted(prompt: Bool = false) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let scanRoles: Set<String> = ["AXLink", "AXButton", "AXImage", "AXHeading", "AXStaticText", "AXTextField",
                                                 "AXTextArea", "AXCheckBox", "AXPopUpButton", "AXTabGroup", "AXCell", "AXGroup"]

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// The element's frame in Cocoa screen points (origin bottom left of the main screen).
    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pt.x, y: h - pt.y - sz.height, width: sz.width, height: sz.height)
    }

    /// The text box that has keyboard focus in another app, if any.
    static func focusedTextBox() -> CGRect? {
        guard trusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        guard let f = attr(sys, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let e = f as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        if pid == getpid() { return nil }
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        let editable = (attr(e, "AXEditable") as? Bool) ?? false
        guard textRoles.contains(role) || editable else { return nil }
        guard let r = frame(e), r.width > 4, r.height > 4 else { return nil }
        return r
    }

    /// Up to `limit` elements of the front window worth scanning (links, buttons, images, headings, text blocks).
    /// Without the Accessibility permission, the front window itself.
    static func scanTargets(limit: Int = 24) -> [CGRect] {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return [] }
        guard trusted() else { return frontWindow(pid: app.processIdentifier).map { [$0] } ?? [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        guard let w = attr(ax, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return [] }
        let win = w as! AXUIElement
        guard let wr = frame(win) else { return [] }
        var out: [CGRect] = []
        var queue: [AXUIElement] = [win]
        var seen = 0
        while !queue.isEmpty, seen < 450 {
            let e = queue.removeFirst(); seen += 1
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids.prefix(40)) }
            guard let role = attr(e, kAXRoleAttribute) as? String, scanRoles.contains(role), let r = frame(e) else { continue }
            let area = r.width * r.height
            guard area > 900, area < wr.width * wr.height * 0.35, wr.contains(r) else { continue }
            if role == "AXGroup", area < 20000 { continue }
            out.append(r)
        }
        out.shuffle()
        let picked = Array(out.prefix(limit))
        return picked.isEmpty ? [wr] : picked
    }

    /// The front window's frame from the window list (needs no permission).
    private static func frontWindow(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"] else { continue }
            if ww < 120 || hh < 80 { continue }
            return CGRect(x: x, y: h - y - hh, width: ww, height: hh)
        }
        return nil
    }

    /// Screen points per physical inch on this screen (from the display's real size); 110 if unknown.
    static func pointsPerInch(_ screen: NSScreen?) -> CGFloat {
        guard let s = screen, let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 110 }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value)).width
        guard mm > 10 else { return 110 }
        return s.frame.width / (mm / 25.4)
    }
}

/// A click-through layer over the whole screen that draws the blue scanning light from the Ghost's eye to an element.
final class ScanOverlayView: NSView {
    var eye: CGPoint = .zero
    var rect: CGRect?
    var k: CGFloat = 0
    /// 0...1 fade, so the light comes on and goes off softly.
    var level: CGFloat = 0

    override var isFlipped: Bool { false }

    override func draw(_ dirty: NSRect) {
        guard let r0 = rect, level > 0.01, let ctx = NSGraphicsContext.current?.cgContext, let win = window else { return }
        let o = win.frame.origin
        let r = r0.offsetBy(dx: -o.x, dy: -o.y)
        let e = CGPoint(x: eye.x - o.x, y: eye.y - o.y)
        let ly = r.maxY - k * r.height
        let blue = CGColor(red: 0.36, green: 0.72, blue: 1, alpha: 1)

        // The light cone: from the eye to the sweep line across the element.
        ctx.saveGState()
        let cone = CGMutablePath()
        cone.move(to: e); cone.addLine(to: CGPoint(x: r.minX, y: ly)); cone.addLine(to: CGPoint(x: r.maxX, y: ly)); cone.closeSubpath()
        ctx.addPath(cone); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [blue.copy(alpha: 0.62 * level)!, blue.copy(alpha: 0.14 * level)!] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: e, end: CGPoint(x: r.midX, y: ly), options: [])
        ctx.restoreGState()

        // The lit part of the element above the sweep line, its outline, and the bright sweep line.
        ctx.saveGState()
        ctx.setFillColor(blue.copy(alpha: 0.18 * level)!)
        ctx.fill(CGRect(x: r.minX, y: ly, width: r.width, height: r.maxY - ly))
        ctx.setShadow(offset: .zero, blur: 10, color: blue.copy(alpha: 0.9 * level))
        ctx.setStrokeColor(blue.copy(alpha: 0.8 * level)!)
        ctx.setLineWidth(1.2)
        ctx.stroke(r.insetBy(dx: -2, dy: -2))
        ctx.setStrokeColor(CGColor(red: 0.75, green: 0.9, blue: 1, alpha: level))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: r.minX - 4, y: ly)); ctx.addLine(to: CGPoint(x: r.maxX + 4, y: ly)); ctx.strokePath()
        ctx.restoreGState()
    }
}
