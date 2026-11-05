import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, th, en
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return tr("Auto")
        case .th: return "ไทย"
        case .en: return "English"
        }
    }
}

enum L10n {
    static var language: AppLanguage = .system

    static var isThai: Bool {
        switch language {
        case .th: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("th") ?? false
        }
    }
}

/// Translate an English UI string. Uses String(format:) when args are given.
func tr(_ english: String, _ args: CVarArg...) -> String {
    let base = L10n.isThai ? (thai[english] ?? english) : english
    return args.isEmpty ? base : String(format: base, arguments: args)
}

private let thai: [String: String] = [
    // Home
    "You're AFK": "คุณ AFK อยู่",
    "Going somewhere?": "จะไปไหนหรือเปล่า?",
    "Close the lid. Agents, builds and downloads keep running.": "พับจอได้เลย agent, build และดาวน์โหลดยังทำงานต่อ",
    "Keep your Mac awake, even with the lid closed.": "ให้ Mac ตื่นอยู่ แม้พับจอแล้ว",
    "Stop": "หยุด",
    "+30m": "+30 นาที",
    "Go AFK": "ไป AFK",
    "left": "เหลือ",
    "Agent mode": "โหมด Agent",
    "Awake only while your AI agents work": "ตื่นเฉพาะตอน AI agent ทำงาน",
    "Connect Claude Code to detect work automatically.": "เชื่อม Claude Code เพื่อตรวจจับงานอัตโนมัติ",
    "Connect": "เชื่อม",
    "All done. Cooling down before sleep": "เสร็จแล้ว รอสักครู่ก่อน sleep",
    "No agents working right now": "ตอนนี้ไม่มี agent ทำงาน",
    "Stop keeping awake for this one": "เลิกค้างเครื่องไว้ให้ตัวนี้",
    "until %@": "ถึง %@",
    "working for %@": "ทำงานมา %@",
    "Lid-closed mode": "โหมดพับจอ",
    "Screen off, sound off, work keeps running": "ดับจอ ปิดเสียง งานยังทำต่อ",
    "Needs a one-time permission": "ต้องขอสิทธิ์ครั้งเดียว",
    "Asks for your password once. Only allows turning lid sleep on and off.": "ขอรหัสผ่านครั้งเดียว อนุญาตแค่เปิด/ปิดการ sleep ตอนพับจอ",
    "Set up": "ตั้งค่า",
    "Lid armed": "พับจอได้",
    "Lid normal": "ฝาปกติ",
    "While you were away": "ระหว่างที่คุณไม่อยู่",
    "lid closed": "พับจอ",
    "battery used": "แบตที่ใช้",
    "agent turns": "รอบ agent",
    "peak heat": "ร้อนสุด",
    "tip: afkpug run -- <cmd>": "ทิป: afkpug run -- <cmd>",
    "Quit": "ออก",

    // Settings
    "Settings": "ตั้งค่า",
    "Language": "ภาษา",
    "Auto": "อัตโนมัติ",
    "When the lid closes": "เมื่อพับจอ",
    "Turn the screen off": "ดับหน้าจอ",
    "Keeps the panel dark under the lid": "ให้จอดับสนิทใต้ฝา",
    "Mute sound": "ปิดเสียง",
    "Restored when you open the lid": "คืนค่าเมื่อเปิดฝา",
    "Low Power Mode on battery": "Low Power Mode ตอนใช้แบต",
    "Also turns on if the Mac gets hot": "เปิดด้วยเมื่อเครื่องร้อน",
    "Only when plugged in": "เฉพาะตอนเสียบปลั๊ก",
    "Lid-closed mode needs a charger": "โหมดพับจอทำงานเฉพาะตอนชาร์จ",
    "Safety": "ความปลอดภัย",
    "Stop at battery": "หยุดเมื่อแบตเหลือ",
    "If the Mac gets critically hot, AFK Pug always lets it sleep.": "ถ้าเครื่องร้อนขั้นวิกฤต AFK Pug จะปล่อยให้ sleep เสมอ",
    "Agents": "Agent",
    "Notify me": "แจ้งเตือน",
    "When an agent finishes or needs you": "เมื่อ agent ทำเสร็จหรือรอคุณ",
    "Wait before sleeping": "รอก่อน sleep",
    "Off": "ปิด",
    "2 min": "2 นาที",
    "5 min": "5 นาที",
    "15 min": "15 นาที",
    "Disconnect": "เลิกเชื่อม",
    "Any other tool: run  afkpug run -- <command>  or  afkpug hold --for 2h  (in ~/.afkpug/bin)":
        "เครื่องมืออื่น: ใช้  afkpug run -- <command>  หรือ  afkpug hold --for 2h  (อยู่ใน ~/.afkpug/bin)",
    "Activity": "กิจกรรม",
    "Nothing yet": "ยังไม่มี",
    "Remove lid-closed permission": "ลบสิทธิ์โหมดพับจอ",

    // Engine: status
    "Low battery, napping": "แบตต่ำ ของีบก่อน",
    "Too hot, cooling down": "ร้อนเกิน ขอพักให้เย็น",
    "Awake until you stop": "ตื่นจนกว่าจะกดหยุด",
    "Staying awake": "ตื่นอยู่",
    "Watching 1 agent": "เฝ้า agent 1 ตัว",
    "Watching %d agents": "เฝ้า agent %d ตัว",
    "Agents done": "Agent ทำเสร็จแล้ว",
    "Napping": "กำลังงีบ",
    "Stopped at %d%%. Plug in to continue": "หยุดที่ %d%% เสียบปลั๊กเพื่อทำต่อ",
    "Your Mac got too hot, so it can sleep now": "เครื่องร้อนเกิน เลยปล่อยให้ sleep",
    "%@ left": "เหลือ %@",
    "Close the lid. Your work keeps running": "พับจอได้ งานยังทำต่อ",
    "Awake while they work, then sleeps": "ตื่นระหว่างทำงาน เสร็จแล้วค่อย sleep",
    "Sleeping in %@": "จะ sleep ใน %@",
    "Wakes when your agents start": "ตื่นเมื่อ agent เริ่มทำงาน",
    "Your Mac sleeps normally": "Mac sleep ตามปกติ",

    // Engine: activity + notifications
    "AFK Pug is ready": "AFK Pug พร้อมแล้ว",
    "Restored normal lid sleep after an unexpected quit": "คืนค่าการ sleep ปกติหลังแอปปิดไปไม่คาดคิด",
    "Awake for %@": "ตื่นอยู่ %@",
    "Stopped. Back to normal sleep": "หยุดแล้ว กลับไป sleep ตามปกติ",
    "Added %@": "เพิ่ม %@",
    "Lid-closed mode is ready": "โหมดพับจอพร้อมแล้ว",
    "Permission was not applied. Please try again.": "ยังไม่ได้รับสิทธิ์ ลองอีกครั้ง",
    "Connected to Claude Code": "เชื่อม Claude Code แล้ว",
    "Disconnected from Claude Code": "เลิกเชื่อม Claude Code แล้ว",
    "Timer finished": "หมดเวลาแล้ว",
    "Time's up": "หมดเวลา",
    "AFK Pug let your Mac go back to sleep.": "AFK Pug ปล่อยให้ Mac กลับไป sleep แล้ว",
    "Battery at %d%%. Letting the Mac sleep": "แบตเหลือ %d%% ปล่อยให้ Mac sleep",
    "Battery low": "แบตต่ำ",
    "AFK Pug stopped at %d%% so your Mac can sleep safely.": "AFK Pug หยุดที่ %d%% เพื่อให้ Mac sleep อย่างปลอดภัย",
    "Mac too hot. Letting it sleep": "เครื่องร้อนเกิน ปล่อยให้ sleep",
    "Too hot": "ร้อนเกิน",
    "AFK Pug stopped so your Mac can cool down.": "AFK Pug หยุดแล้ว ให้เครื่องได้พักเย็นลง",
    "%@ finished": "%@ ทำเสร็จแล้ว",
    "Your agent is done. AFK Pug will let the Mac sleep soon.": "agent ทำเสร็จแล้ว อีกสักครู่ AFK Pug จะปล่อยให้ Mac sleep",
    "%@ needs you": "%@ รอคุณอยู่",
    "Your agent is waiting for your input.": "agent กำลังรอคำตอบจากคุณ",
    "%@ started working": "%@ เริ่มทำงาน",
    "Lid closed. Still working": "พับจอแล้ว ยังทำงานต่อ",
    "Welcome back": "ยินดีต้อนรับกลับ",
    "Lid closed for %@.": "พับจอไป %@",
    " Battery %d%% → %d%%.": " แบต %d%% → %d%%",
    " %d agent turn(s) finished.": " agent ทำเสร็จ %d รอบ",

    // Sensors / agents / formatting
    "Cool": "เย็น",
    "Warm": "อุ่น",
    "Hot": "ร้อน",
    "Unknown": "ไม่ทราบ",
    "Hold · %@": "ค้างไว้ · %@",
    "Manual hold": "ค้างเอง",
    "under a minute": "ไม่ถึงนาที",
    "%dh %dm": "%d ชม. %d นาที",
    "%dm": "%d นาที",
    "%dh": "%d ชม.",
    "%dm·short": "%d น.",
    // v0.2
    "Lock the screen": "ล็อกหน้าจอ",
    "Nobody can use your Mac while you're away": "ไม่มีใครแอบใช้เครื่องตอนคุณไม่อยู่",
    "Pause chat apps": "หยุดแอปแชทชั่วคราว",
    "Slack, Discord, LINE and others. Resumed when you open the lid": "Slack, Discord, LINE และอื่นๆ กลับมาทำงานเมื่อเปิดฝา",
    "Detect other agents": "ตรวจจับ agent อื่นด้วย",
    "Codex, Gemini CLI, Cursor Agent, Aider, OpenCode and more": "Codex, Gemini CLI, Cursor Agent, Aider, OpenCode และอื่นๆ",
    "Let agents keep the Mac awake": "ให้ agent สั่งค้างเครื่องเองได้",
    "Adds an AFK Pug tool to Claude Code for long builds and deploys": "เพิ่มเครื่องมือ AFK Pug ให้ Claude Code ใช้ตอน build หรือ deploy นาน",
    "Agents can now ask AFK Pug to stay awake": "agent สั่งค้างเครื่องเองได้แล้ว",
    "Could not run the claude command. Is Claude Code installed?": "เรียกคำสั่ง claude ไม่ได้ ติดตั้ง Claude Code แล้วหรือยัง?",
    "Phone notifications": "แจ้งเตือนถึงมือถือ",
    "Could not connect: %@": "เชื่อมไม่สำเร็จ: %@",
    "Could not find the claude command. Is Claude Code installed?": "หาคำสั่ง claude ไม่เจอ ติดตั้ง Claude Code แล้วหรือยัง?",
    "claude mcp add failed. Please try again.": "claude mcp add ไม่สำเร็จ ลองอีกครั้ง",
    "Working…": "กำลังทำ…",
    "1 agent": "agent 1 ตัว",
    "%d agents": "agent %d ตัว",
    "Awake": "ตื่นอยู่",
    "Agents done. Sleeping in %@": "agent เสร็จแล้ว จะ sleep ในอีก %@",
    "Sleeps normally once that stops": "หยุดเมื่อไหร่ก็ sleep ตามปกติ",
    "%dm %ds": "%d นาที %d วินาที",
    "%ds": "%d วินาที",
    "Updated the Claude Code connection": "อัปเดตการเชื่อม Claude Code แล้ว",
    "Install the free ntfy app on your phone, subscribe to a topic name only you know, then enter the same name here.": "ติดตั้งแอป ntfy (ฟรี) บนมือถือ กด Subscribe ชื่อหัวข้อที่รู้คนเดียว แล้วใส่ชื่อเดียวกันตรงนี้",
    "topic name, e.g. afkpug-nathaporn-82": "ชื่อหัวข้อ เช่น afkpug-nathaporn-82",
    "Test": "ทดสอบ",
    "Test notification. Your phone is connected.": "ทดสอบแจ้งเตือน มือถือเชื่อมต่อแล้ว",
    "Start automatically": "เริ่มเองอัตโนมัติ",
    "When the charger is connected": "เมื่อเสียบสายชาร์จ",
    "Stays awake whenever it's plugged in": "ตื่นอยู่ตลอดที่เสียบปลั๊ก",
    "While these apps are open": "ระหว่างที่แอปเหล่านี้เปิดอยู่",
    "e.g. Xcode, Docker, OBS": "เช่น Xcode, Docker, OBS",
    "Shortcut": "คีย์ลัด",
    "⌥⌘A starts or stops AFK": "⌥⌘A เริ่มหรือหยุด AFK",
    "Works from any app": "กดได้จากทุกแอป",
    "Awake: %@": "ตื่นอยู่: %@",
    "charger connected": "เสียบสายชาร์จ",
    "music playing": "กำลังเล่นเพลง",
    "Keep music playing": "เปิดเพลงต่อได้ตอนพับจอ",
    "YouTube, Spotify, Apple Music keep playing and sound stays on": "YouTube, Spotify, Apple Music เล่นต่อ เสียงไม่ถูกปิด",
]
