import AppKit
import Carbon

/// Нажатие клавиши: код + Shift/Caps. Слово храним нажатиями, а не буквами — так его можно прочитать в любой раскладке.
struct Key: Equatable {
    let code: UInt16
    var shift = false
    var caps = false
}

/// Раскладка клавиатуры из системного списка (`TISInputSource`).
struct KeyLayout {
    let source: TISInputSource
    let id: String
    let lang: String

    init?(_ source: TISInputSource) {
        guard let id: String = Self.property(source, kTISPropertyInputSourceID),
              let lang = (Self.property(source, kTISPropertyInputSourceLanguages) as [String]?)?.first else { return nil }
        self.source = source
        self.id = id
        self.lang = lang
    }

    /// Что эти нажатия напечатают в этой раскладке.
    func translate(_ keys: [Key]) -> String {
        guard let data: CFData = Self.property(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let keyboard = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var result = ""
        for key in keys {
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let mods = UInt32(((key.shift ? shiftKey : 0) | (key.caps ? alphaLock : 0)) >> 8)
            UCKeyTranslate(keyboard, key.code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            result += String(utf16CodeUnits: chars, count: length)
        }
        return result
    }

    func select() { TISSelectInputSource(source) }

    /// Включённые раскладки (`all: true` — все установленные в системе, для selftest).
    static func list(all: Bool = false) -> [KeyLayout] {
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
        let sources = TISCreateInputSourceList(filter, all).takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap(KeyLayout.init)
    }

    static var current: KeyLayout? { KeyLayout(TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()) }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

/// Решение «набрано не в той раскладке?». Идеи из открытых переключателей (layout-switcher, RuSwitcher, KeySwitcher):
/// слово — это нажатия; меняем, только если как набрано — не слово, а в другой раскладке — слово системного словаря.
/// Словарь не знает ни того, ни другого (жаргон, формы: «ltdjgcjd» — «девопсов») — решает статистика троек букв.
/// Двухбуквенные — только по списку частых (словарь на двух буквах врёт). Одиночные буквы сами по себе не трогаем.
@MainActor
enum LayoutRules {
    /// `code` — строгий режим (редакторы и терминалы): английское не превращаем в русское,
    /// если это похоже на код — знаки внутри, camelCase, короче 3 букв.
    static func shouldSwitch(typed: String, meant: String, from: String, to: String,
                             code: Bool = false, exceptions: Set<String> = []) -> Bool {
        let word = core(typed), other = core(meant)
        guard word.count >= 2, other.count >= 2, other.allSatisfy(\.isLetter),
              !exceptions.contains(word.lowercased()), !exceptions.contains(other.lowercased()) else { return false }
        // Набирали латиницей код: `a.b`, `x[i]`, `getUser`, `fn` — не наше дело.
        if code, from == "en", word != typed || word.count < 3 || !word.allSatisfy(\.isLetter) || isCamel(word) {
            return false
        }
        // «,fu» — это «баг»: в английской раскладке `,` — русская «б», так что со знаками внутри это не слово.
        guard !(word.allSatisfy(\.isLetter) && isWord(word, lang: from)) else { return false }
        if isWord(other, lang: to) { return true }
        // Латиницу в коде по статистике не трогаем: идентификаторы бывают какие угодно.
        guard !(code && from == "en"), word.count >= 4, word.allSatisfy(\.isLetter),
              let odd = strangeness(word, lang: from), let usual = strangeness(other, lang: to) else { return false }
        // Порог подобран на 20 тыс. слов и 4 тыс. идентификаторов из кода: 0 ложных, ловит ~70% (40 → ~0.7, 30 → ~0.88 и 1 ложное).
        return odd - usual > 40
    }

    /// Средняя цена троек букв: у настоящих слов 60–100, у набранных не в той раскладке 130+. nil — нет таблицы.
    static func strangeness(_ word: String, lang: String) -> Double? {
        guard let (unseen, table) = trigrams[lang] else { return nil }
        let padded = Array("^^" + word.lowercased().replacingOccurrences(of: "ё", with: "е") + "$")
        let costs = (0..<padded.count - 2).map { table[String(padded[$0..<$0 + 3])] ?? unseen }
        return costs.reduce(0, +) / Double(costs.count)
    }

    /// Разбирается один раз, при первом слове (~14 тыс. троек).
    private static let trigrams: [String: (Double, [String: Double])] = layoutTrigrams.mapValues { entry in
        (entry.unseen, Dictionary(entry.table.split(whereSeparator: \.isWhitespace).map {
            (String($0.prefix(3)), Double($0.dropFirst(3))!)
        }, uniquingKeysWith: { a, _ in a }))
    }

    /// Короткое слово, оставленное как есть, но в другой раскладке — тоже слово: «b» → «и», «z» → «я».
    /// Само по себе ничего не доказывает; чиним, только когда следующее слово переключили.
    static func isMistypedShort(_ keys: [Key], from: KeyLayout, to: KeyLayout) -> Bool {
        let typed = from.translate(keys).lowercased(), meant = to.translate(keys).lowercased()
        if keys.count == 1 {
            return oneLetterWords[from.lang]?.contains(typed) != true && oneLetterWords[to.lang]?.contains(meant) == true
        }
        return core(meant) == meant && meant.count >= 2 && isWord(meant, lang: to.lang)
    }

    private static let oneLetterWords: [String: Set<String>] = [
        "ru": ["я", "в", "с", "к", "о", "у", "а", "и"],
        "en": ["a", "i"],
    ]

    static func isWord(_ text: String, lang: String) -> Bool {
        // Проверщик пропускает всё капсом («GHBDTN»), поэтому проверяем в нижнем регистре.
        let word = text == text.uppercased() ? text.lowercased() : text
        let lower = word.lowercased()
        if word.count == 2 { return shortWords[lang]?.contains(lower) == true }
        if knownWords[lang]?.contains(lower) == true { return true }
        guard NSSpellChecker.shared.availableLanguages.contains(where: { $0 == lang || $0.hasPrefix(lang + "_") })
        else { return false }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                                   inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// «привет,» → «привет»: знаки по краям — не часть слова.
    static func core(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    private static func isCamel(_ word: String) -> Bool {
        word.dropFirst().contains { $0.isUppercase } && word != word.uppercased()
    }

    // ponytail: короткие слова и термины — ручные списки; расширять, когда что-то конкретное не переключается.
    private static let shortWords: [String: Set<String>] = [
        "ru": ["не", "на", "то", "по", "но", "за", "из", "от", "до", "он", "же", "мы", "вы", "ты", "да", "ну", "уж",
               "ли", "бы", "её", "их", "ей", "им", "ко", "со", "во", "об"],
        "en": ["to", "of", "in", "it", "is", "be", "as", "at", "so", "we", "he", "by", "or", "on", "do", "if", "me",
               "my", "up", "an", "go", "no", "us", "am", "hi", "ok"],
    ]

    /// Слова, которых нет в системном словаре, но которые печатают постоянно.
    /// Русское прочтение каждого не должно быть русским словом (проверяется в selftest).
    private static let knownWords: [String: Set<String>] = [
        "en": Set("""
            api async await bash brew cli config css csv curl docker env git github gitlab grep html http https ios
            json jwt kubectl localhost macos nginx npm npx pnpm postgres regex repo sdk sql ssh sudo swift swiftui
            tmux url utf vscode xcode yaml yml zsh claude cursor typescript javascript nodejs frontend backend
            """.split(whereSeparator: \.isWhitespace).map(String.init)),
        "ru": ["баг", "баги", "бэкенд", "фронтенд", "коммит", "пуш", "мерж", "деплой", "релиз", "линтер", "кэш"],
    ]
}

/// Что набрано с последнего сдвига каретки. Отдельно от перехвата клавиш, чтобы selftest прогонял целые фразы.
@MainActor
struct Typing {
    /// Стереть `erase` символов и напечатать `text`, переключиться на `target`.
    struct Fix {
        let erase: Int
        let text: String
        let target: KeyLayout
    }

    /// Слово, которое сейчас набирается.
    private(set) var word: [Key] = []
    /// Короткие слова прямо перед ним, оставленные как есть, через один пробел («z b» перед «ghbdtn»).
    private var recent: [[Key]] = []
    /// Последний законченный кусок — для ручного перевода. `auto` — его заменили мы.
    private var last: (words: [[Key]], from: KeyLayout, to: KeyLayout, auto: Bool)?
    /// Пробелы после `last`.
    private var spaces = 0

    mutating func reset() { self = Typing() }

    mutating func letter(_ key: Key) {
        if word.isEmpty {
            if spaces != 1 { recent = [] } // два пробела или что-то другое — это уже не одна фраза
            last = nil
            spaces = 0
        }
        word.append(key)
    }

    mutating func backspace() {
        if word.isEmpty { reset() } else { word.removeLast() }
    }

    /// Конец слова: пробел или (вне кода) Return/Tab.
    mutating func end(space: Bool, from: KeyLayout, to: KeyLayout, code: Bool, exceptions: Set<String>) -> Fix? {
        guard !word.isEmpty else {
            if space, last != nil { spaces += 1 } else { reset() }
            return nil
        }
        let keys = word
        word = []
        spaces = space ? 1 : 0
        let typed = from.translate(keys)
        guard LayoutRules.shouldSwitch(typed: typed, meant: to.translate(keys), from: from.lang, to: to.lang,
                                       code: code, exceptions: exceptions) else {
            // Длинное слово осталось как есть — раскладка верная, короткие перед ним уже не чиним.
            recent = space && typed.count <= 4 ? Array((recent + [keys]).suffix(3)) : []
            last = space ? ([keys], from, to, false) : nil
            return nil
        }
        var words = [keys]
        if !(code && from.lang == "en") {
            for short in recent.reversed() {
                guard LayoutRules.isMistypedShort(short, from: from, to: to) else { break }
                words.insert(short, at: 0)
            }
        }
        recent = []
        last = space ? (words, from, to, true) : nil
        return Fix(erase: words.map { from.translate($0).count }.reduce(0, +) + words.count - 1,
                   text: words.map { to.translate($0) }.joined(separator: " "), target: to)
    }

    /// Двойной ⌥: переводит набираемое слово или последний кусок. Отмена нашей замены возвращает слово,
    /// которое больше не трогать.
    mutating func manual(pair: (KeyLayout, KeyLayout)?) -> (fix: Fix, exception: String?)? {
        defer { reset() }
        if !word.isEmpty, let (from, to) = pair {
            return (Fix(erase: from.translate(word).count, text: to.translate(word), target: to), nil)
        }
        guard let last else { return nil }
        let (shown, target) = last.auto ? (last.to, last.from) : (last.from, last.to)
        let tail = String(repeating: " ", count: spaces)
        let erase = last.words.map { shown.translate($0).count }.reduce(0, +) + last.words.count - 1 + spaces
        let text = last.words.map { target.translate($0) }.joined(separator: " ") + tail
        let exception = last.auto ? LayoutRules.core(last.from.translate(last.words.last!)).lowercased() : nil
        return (Fix(erase: erase, text: text, target: target), exception)
    }
}

/// Проверки: `swift run BigIsland --selftest`. Нужны установленные раскладки ABC/US и Russian.
@MainActor
func layoutSelfTest() {
    let all = KeyLayout.list(all: true)
    guard let en = all.first(where: { $0.id == "com.apple.keylayout.ABC" || $0.id == "com.apple.keylayout.US" }),
          let ru = all.first(where: { $0.id == "com.apple.keylayout.Russian" }) else { fatalError("нет раскладок ABC/Russian") }
    // Буква → нажатие в английской раскладке.
    var table: [Character: Key] = [:]
    for shift in [true, false] {
        for code in UInt16(0)...50 {
            let key = Key(code: code, shift: shift), char = en.translate([key])
            if char.count == 1 { table[char.first!] = key }
        }
    }
    func keys(_ text: String) -> [Key] { text.map { table[$0]! } }
    /// Набрали латиницей `text`: переключит ли на русский.
    func toRu(_ text: String, code: Bool = false) -> Bool {
        LayoutRules.shouldSwitch(typed: text, meant: ru.translate(keys(text)), from: "en", to: "ru", code: code)
    }
    /// Набрали те же клавиши в русской раскладке (на экране кириллица): переключит ли на английский.
    func toEn(_ text: String, code: Bool = false) -> Bool {
        LayoutRules.shouldSwitch(typed: ru.translate(keys(text)), meant: text, from: "ru", to: "en", code: code)
    }

    precondition(ru.translate(keys("ghbdtn")) == "привет")
    precondition(toRu("ghbdtn") && toRu("GHBDTN") && toRu("Ghbdtn"))
    precondition(!toRu("hello") && !toRu("HELLO") && !toRu("kubectl") && !toRu("vk"))
    precondition(toEn("hello") && toEn("kubectl") && toEn("const") && toEn("func"))
    precondition(!toEn("ghbdtn"))
    precondition(toRu("yt") && toRu("ns") && !toRu("to") && !toRu("in"))       // не, ты; to/in — слова
    precondition(toRu(",fu"))                                                   // баг
    // Строгий режим кода: латинский код не трогаем, русский текст и кириллица вместо кода — чиним.
    precondition(toRu("ghbdtn", code: true) && toRu("rjvvtynfhbq", code: true)) // привет, комментарий
    precondition(!toRu("ns", code: true) && !toRu("yt", code: true))            // короткие идентификаторы
    precondition(!toRu("ghbdtn.ns", code: true) && !toRu("getUser", code: true) && !toRu("b[", code: true))
    precondition(toEn("const", code: true) && toEn("return", code: true))       // сщтые → const
    // Нет в словаре — решает статистика: «ltdjgcjd» → «девопсов», а «девопсов» набранное по-русски остаётся.
    precondition(LayoutRules.isWord("девопсов", lang: "ru") == false, "девопсов в словаре — нужен другой пример")
    precondition(toRu("ltdjgcjd") && !toEn("ltdjgcjd"))
    precondition(!toRu("ltdjgcjd", code: true))                                // латиница в коде — только по словарю
    precondition(!toRu("kwargs") && !toRu("stdin") && !toRu("mkdir") && !toRu("nginx"))

    // Целые фразы через тот же `Typing`, что и перехват клавиш. Набираем клавишами английской раскладки,
    // `shown` — что осталось на экране после замен.
    func screen(_ phrase: String, code: Bool = false) -> String {
        var typing = Typing(), shown = "", from = en, to = ru
        for char in phrase {
            if char == " " {
                if let fix = typing.end(space: true, from: from, to: to, code: code, exceptions: []) {
                    shown = String(shown.dropLast(fix.erase)) + fix.text
                    (from, to) = (to, from)
                }
                shown += " "
                continue
            }
            typing.letter(table[char]!)
            shown += from.translate([table[char]!])
        }
        return shown
    }
    func check(_ phrase: String, _ expected: String, code: Bool = false) {
        let shown = screen(phrase, code: code)
        precondition(shown == expected, "«\(phrase)» → «\(shown)», ждали «\(expected)»")
    }
    check("ghbdtn vbh ", "привет мир ")
    check("b ghbdtn ", "и привет ")                     // «b» чиним задним числом
    check("z b ghbdtn ", "я и привет ")
    check("ye ns ghbdtn ", "ну ты привет ")
    check("to ghbdtn ", "to привет ")                   // «to» — слово, остаётся
    check("press the ghbdtn ", "press the привет ")
    check("hello b ghbdtn ", "hello и привет ")         // до «hello» не доходим
    check("b  ghbdtn ", "b  привет ")                   // два пробела — уже не одна фраза
    check("ltdjgcjd ghbdtn ", "девопсов привет ")
    check("kubectl nginx ", "kubectl nginx ")
    check("b ghbdtn ", "b привет ", code: true)         // в коде «b» — скорее переменная

    // Встроенные слова не должны перекрывать настоящие русские («vue» читается как «мгу»).
    for word in ["api", "npm", "git", "json", "swift", "zsh", "kubectl", "claude", "cursor"] {
        precondition(!LayoutRules.isWord(ru.translate(keys(word)), lang: "ru"), "\(word) перекрывает русское слово")
    }
}
