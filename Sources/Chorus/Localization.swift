import Foundation

/// Lightweight in-app localization. We don't use .strings / String Catalogs because the app
/// is SPM-built and hand-packaged into the .app — wiring .lproj bundles into that is fiddly.
/// Instead `L("key")` looks the string up in `L10nTable` by the current language, which the
/// user picks in Settings (system / 中文 / English) and can switch instantly.

/// The effective language code ("zh" or "en") given the user's setting + system preference.
func currentLang() -> String {
    switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
    case "zh": return "zh"
    case "en": return "en"
    default:
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? "zh" : "en"
    }
}

/// Localized string for `key`. Falls back to English, then the key itself.
func L(_ key: String) -> String {
    let lang = currentLang()
    return L10nTable[key]?[lang] ?? L10nTable[key]?["en"] ?? key
}

/// Localized format string applied to args, e.g. Lf("panel.reload", name).
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Body text for the "all AIs finished" notification. Minimal lines, rotated so a message
/// you see on every broadcast stays fresh instead of feeling robotic. Localized.
func completionNotificationBody() -> String {
    let pool = currentLang() == "zh"
        ? ["都好了", "好了", "都答完了", "答案就绪"]
        : ["All done.", "Ready.", "All in.", "Answers in."]
    return pool.randomElement() ?? pool[0]
}

let L10nTable: [String: [String: String]] = [
    // MARK: Composer + panel chrome (main window)
    "composer.placeholder": [
        "zh": "问所有 AI…    ⌘↩ 发送 · ⌘V 粘贴图片",
        "en": "Ask all AIs…    ⌘↩ to send · ⌘V to paste image",
    ],
    "composer.imageAttached": ["zh": "已附加图片", "en": "Image attached"],
    "composer.removeImage": ["zh": "移除已附加的图片", "en": "Remove attached image"],
    "composer.sendHelp": ["zh": "发送给全部 (⌘↩)", "en": "Send to all (⌘↩)"],
    "menu.newChat": ["zh": "新对话", "en": "New chat"],
    "menu.reloadAll": ["zh": "刷新全部", "en": "Reload all"],
    "menu.panels": ["zh": "面板", "en": "Panels"],
    "menu.settings": ["zh": "设置…", "en": "Settings…"],
    "menu.actions": ["zh": "操作", "en": "Actions"],
    "panel.reload": ["zh": "重载 %@", "en": "Reload %@"],
    "panel.hide": ["zh": "隐藏 %@", "en": "Hide %@"],

    // MARK: Quick input
    "quick.placeholder": [
        "zh": "问所有 AI…",
        "en": "Ask all AIs…",
    ],
    "quick.pronounce": ["zh": "朗读  (⌘L)", "en": "Pronounce  (⌘L)"],
    "quick.mic": ["zh": "语音输入", "en": "Voice input"],
    "quick.micStop": ["zh": "停止录音", "en": "Stop recording"],
    "quick.micDenied": ["zh": "麦克风/语音识别权限被拒——请到系统设置开启", "en": "Mic / speech permission denied — enable it in System Settings"],
    "quick.chipHelp": ["zh": "以「%@：」为前缀发送给所有 AI", "en": "Send to all AIs with “%@: ” prepended"],

    // MARK: Settings — sections
    "settings.section.language": ["zh": "语言", "en": "Language"],
    "settings.section.quickInput": ["zh": "快捷输入", "en": "Quick Input"],
    "settings.section.providers": ["zh": "AI 服务", "en": "AI Providers"],
    "settings.section.quickPrompts": ["zh": "快捷提示", "en": "Quick Prompts"],
    "settings.section.notifications": ["zh": "通知", "en": "Notifications"],

    // MARK: Settings — language
    "settings.language.label": ["zh": "界面语言", "en": "Interface language"],
    "settings.language.system": ["zh": "跟随系统", "en": "System"],

    // MARK: Notifications
    "notif.testTitle": ["zh": "Chorus 测试", "en": "Chorus test"],
    "notif.testBody": ["zh": "看到这条就说明通知正常 ✅", "en": "If you see this, notifications work. ✅"],

    // MARK: Menu bar
    "menubar.idle": ["zh": "都闲着呢", "en": "All idle"],
    "menubar.thinking": ["zh": "%d 个在思考…", "en": "%d thinking…"],
    "menubar.open": ["zh": "打开 Chorus", "en": "Open Chorus"],
    "menubar.quit": ["zh": "退出 Chorus", "en": "Quit Chorus"],
    "settings.section.menubar": ["zh": "菜单栏", "en": "Menu Bar"],
    "settings.menubar.show": ["zh": "在菜单栏显示图标", "en": "Show menu bar icon"],
    "settings.menubar.desc": [
        "zh": "在菜单栏常驻图标：显示是否有 AI 正在回答，点开可快速新建对话/刷新/打开主窗。开启时，关掉主窗 app 仍留在菜单栏；关闭后，关掉窗口即退出。",
        "en": "Keep an icon in the menu bar: shows whether any AI is responding, with quick actions. When on, closing the window keeps the app alive in the menu bar; when off, closing the window quits.",
    ],

    // MARK: Settings — API models
    "settings.section.apiModels": ["zh": "API 模型", "en": "API Models"],
    "settings.api.desc": [
        "zh": "接入任何 OpenAI 兼容接口（OpenAI / DeepSeek / Groq / OpenRouter / 本地 Ollama 等），和网页 AI 并排。密钥安全存于钥匙串。",
        "en": "Connect any OpenAI-compatible endpoint (OpenAI / DeepSeek / Groq / OpenRouter / local Ollama…) alongside the web AIs. Keys are stored securely in the Keychain.",
    ],
    "settings.api.name": ["zh": "名称", "en": "Name"],
    "settings.api.model": ["zh": "模型", "en": "Model"],
    "settings.api.key": ["zh": "API 密钥（本地模型可留空）", "en": "API key (leave blank for local)"],
    "settings.api.add": ["zh": "添加", "en": "Add"],
    "settings.api.remove": ["zh": "移除 %@", "en": "Remove %@"],
    "settings.api.presets": ["zh": "快速填充", "en": "Quick fill"],
    "settings.api.local": ["zh": "本地", "en": "local"],

    // MARK: Settings — minimal mode
    "settings.minimalMode": ["zh": "简洁模式", "en": "Minimal mode"],
    "settings.minimalMode.desc": [
        "zh": "隐藏输入框里的快捷键提示和设置项的说明文字，界面更清爽。",
        "en": "Hide input shortcut hints and the description text under settings for a cleaner look.",
    ],

    // MARK: Settings — appearance
    "settings.section.appearance": ["zh": "外观", "en": "Appearance"],
    "settings.appearance.label": ["zh": "明暗模式", "en": "Theme"],
    "settings.appearance.system": ["zh": "跟随系统", "en": "System"],
    "settings.appearance.light": ["zh": "浅色", "en": "Light"],
    "settings.appearance.dark": ["zh": "深色", "en": "Dark"],
    "settings.appearance.desc": [
        "zh": "切换 Chorus 界面的明暗。跟随系统的 AI 网站也会一起切换；少数有独立主题开关的站点需在站内自行设置。",
        "en": "Switch Chorus between light and dark. AI sites that follow the system theme switch too; a few sites with their own theme toggle must be set inside the site.",
    ],
    "settings.warmWeb": ["zh": "给 AI 网页染上暖色调", "en": "Warm-tint the AI web pages"],
    "settings.warmWeb.desc": [
        "zh": "在各家 AI 网页上叠一层很淡的奶油色，让它们更贴近 Chorus 的暖色外壳。纯外观、本地实现，不影响登录或账号安全；浅色模式下效果最明显。实验功能，觉得不顺眼随时关。",
        "en": "Overlays a faint cream layer on each AI page so they lean toward Chorus's warm shell. Purely cosmetic and local — it never touches your login or account. Most visible in light mode. Experimental; turn it off anytime.",
    ],

    // MARK: Settings — quick input
    "settings.hotkey.label": ["zh": "快捷输入快捷键", "en": "Quick input shortcut"],
    "settings.hotkey.recording": ["zh": "按下组合键…", "en": "Press combo…"],
    "settings.hotkey.reset": ["zh": "重置为 ⌘⇧C", "en": "Reset to ⌘⇧C"],
    "settings.foregroundOnSend": ["zh": "发送后将 Chorus 切到最前", "en": "Bring Chorus to front after sending"],
    "settings.autoPaste": ["zh": "唤出时自动粘贴剪贴板", "en": "Auto-paste clipboard when summoning"],
    "settings.quickInput.desc": [
        "zh": "在任意位置按快捷键唤出悬浮输入框。输入后回车广播给所有可见 AI。⌘V 粘贴图片。",
        "en": "Press the shortcut anywhere to summon a floating input. Type, hit Return to broadcast to all visible AIs. Cmd+V pastes an image.",
    ],

    // MARK: Settings — providers
    "settings.restoreSession": ["zh": "启动时重开上次对话", "en": "Reopen last conversation on launch"],
    "settings.restoreSession.desc": [
        "zh": "开启后，每个面板会重开你上次停留的对话，而不是新建对话。",
        "en": "When on, each panel reopens the conversation you left it on instead of starting a new chat.",
    ],
    "settings.providers.desc": [
        "zh": "用网址添加任意 AI。内置三家针对图片上传做了适配；新增的用通用方式广播文字（多数聊天站点可用）。",
        "en": "Add any AI by its web URL. The three built-ins are tuned for image upload; added ones broadcast text via a generic method (most chat sites work).",
    ],
    "settings.providers.builtin": ["zh": "内置", "en": "Built-in"],
    "settings.providers.quickAdd": ["zh": "快速添加", "en": "Quick add"],
    "settings.providers.name": ["zh": "名称", "en": "Name"],
    "settings.providers.add": ["zh": "添加", "en": "Add"],
    "settings.providers.remove": ["zh": "移除 %@", "en": "Remove %@"],

    // MARK: Settings — notifications
    "settings.notify.picker": ["zh": "全部 AI 完成时提醒", "en": "Alert when all AIs finish"],
    "settings.notify.off": ["zh": "关闭", "en": "Off"],
    "settings.notify.quickOnly": ["zh": "仅快捷输入", "en": "Only from quick input"],
    "settings.notify.always": ["zh": "始终", "en": "Always"],
    "settings.notify.desc": [
        "zh": "当所有可见 AI 都输出完毕时，播放系统提示音并显示横幅。若 Chorus 窗口已在最前则跳过。",
        "en": "Plays the system notification sound and shows a banner when all visible AIs have finished streaming. Skipped if the Chorus window is already in front.",
    ],
    "settings.notify.test": ["zh": "发送测试通知", "en": "Send test notification"],
    "settings.notify.testDesc": ["zh": "点击验证权限/送达是否正常。", "en": "Click to verify permission/delivery is working."],
    "settings.notify.waitFor": ["zh": "提醒前等待这些 AI", "en": "Wait for these AIs before notifying"],
    "settings.notify.waitDesc": [
        "zh": "取消勾选慢/不稳定的 AI（如 Gemini），它们就不会拖住提醒。广播仍会发给它们，回答完成时自然到达。",
        "en": "Uncheck slow/flaky AIs (e.g. Gemini) so they don't block the alert. The broadcast still goes to them; their reply just arrives whenever it finishes.",
    ],

    // MARK: Settings — quick prompts
    "settings.prompts.desc": [
        "zh": "在快捷输入里点一个标签，就以该文字为前缀立即广播。",
        "en": "Tapping a chip in the quick input instantly broadcasts with that text as a prefix.",
    ],
    "settings.prompts.textChips": ["zh": "文字模式标签", "en": "Text-mode chips"],
    "settings.prompts.imageChips": ["zh": "图片模式标签（附加图片时显示）", "en": "Image-mode chips (shown when an image is attached)"],
    "settings.prompts.restore": ["zh": "恢复默认", "en": "Restore defaults"],
    "settings.prompts.addPlaceholder": ["zh": "添加一个提示…", "en": "Add a prompt…"],
]
