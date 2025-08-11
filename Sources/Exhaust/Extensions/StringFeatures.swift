//
//  StringFeatures.swift
//  Exhaust
//
//  Created by Claude on 10/8/2025.
//

import Foundation

/// A feature set for extracting meaningful properties from strings for classification purposes.
/// Uses a 64-bit option set to efficiently encode string characteristics that might correlate
/// with test outcomes or generator behaviors.
public struct StringFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
    
    // MARK: - Character Composition (bits 0-15)
    
    /// String contains only uppercase letters
    public static let isAllUppercase     = StringFeatures(rawValue: 1 << 0)
    /// String contains at least one uppercase letter
    public static let containsUppercase  = StringFeatures(rawValue: 1 << 1)
    /// String contains only lowercase letters
    public static let isAllLowercase     = StringFeatures(rawValue: 1 << 2)
    /// String contains at least one lowercase letter
    public static let containsLowercase  = StringFeatures(rawValue: 1 << 3)
    /// String contains only digits
    public static let isAllDigits        = StringFeatures(rawValue: 1 << 4)
    /// String contains at least one digit
    public static let containsDigits     = StringFeatures(rawValue: 1 << 5)
    /// String contains only ASCII characters (0-127)
    public static let isAscii            = StringFeatures(rawValue: 1 << 6)
    /// String contains non-ASCII (Unicode) characters
    public static let containsUnicode    = StringFeatures(rawValue: 1 << 7)
    /// String contains whitespace characters
    public static let containsWhitespace = StringFeatures(rawValue: 1 << 8)
    /// String contains punctuation marks
    public static let containsPunctuation = StringFeatures(rawValue: 1 << 9)
    /// String contains symbol characters
    public static let containsSymbols    = StringFeatures(rawValue: 1 << 10)
    /// String contains only letters and digits
    public static let isAlphanumeric     = StringFeatures(rawValue: 1 << 11)
    /// String contains only printable characters
    public static let isPrintable        = StringFeatures(rawValue: 1 << 12)
    /// String contains control characters
    public static let containsControlChars = StringFeatures(rawValue: 1 << 13)
    
    // MARK: - Length Patterns (bits 16-23)
    
    /// String is empty
    public static let isEmpty           = StringFeatures(rawValue: 1 << 16)
    /// String has exactly one character
    public static let isSingleChar      = StringFeatures(rawValue: 1 << 17)
    /// String is short (2-5 characters)
    public static let isShort           = StringFeatures(rawValue: 1 << 18)
    /// String is medium length (6-20 characters)
    public static let isMedium          = StringFeatures(rawValue: 1 << 19)
    /// String is long (21-100 characters)
    public static let isLong            = StringFeatures(rawValue: 1 << 20)
    /// String is very long (>100 characters)
    public static let isVeryLong        = StringFeatures(rawValue: 1 << 21)
    
    // MARK: - Structure Patterns (bits 24-35)
    
    /// String has repeated consecutive characters
    public static let hasRepeatedChars   = StringFeatures(rawValue: 1 << 24)
    /// String consists of all the same character
    public static let isAllSameChar      = StringFeatures(rawValue: 1 << 25)
    /// String reads the same forwards and backwards
    public static let isPalindrome       = StringFeatures(rawValue: 1 << 26)
    /// String alternates between uppercase/lowercase
    public static let hasAlternatingCase = StringFeatures(rawValue: 1 << 27)
    /// String starts with a capital letter
    public static let startsWithCapital  = StringFeatures(rawValue: 1 << 28)
    /// String ends with punctuation
    public static let endsWithPunctuation = StringFeatures(rawValue: 1 << 29)
    /// String starts with a digit
    public static let startsWithDigit    = StringFeatures(rawValue: 1 << 30)
    /// String contains only a single word (no spaces)
    public static let isSingleWord       = StringFeatures(rawValue: 1 << 31)
    /// String contains multiple words
    public static let isMultiWord        = StringFeatures(rawValue: 1 << 32)
    /// String has consistent case (all upper or all lower)
    public static let hasConsistentCase  = StringFeatures(rawValue: 1 << 33)
    
    // MARK: - Domain-Specific Patterns (bits 36-47)
    
    /// String looks like an email address
    public static let looksLikeEmail     = StringFeatures(rawValue: 1 << 36)
    /// String looks like a URL
    public static let looksLikeURL       = StringFeatures(rawValue: 1 << 37)
    /// String looks like a file name with extension
    public static let looksLikeFileName  = StringFeatures(rawValue: 1 << 38)
    /// String contains path separators
    public static let containsPath       = StringFeatures(rawValue: 1 << 39)
    /// String looks like a version number
    public static let looksLikeVersion   = StringFeatures(rawValue: 1 << 40)
    /// String looks like hexadecimal
    public static let looksLikeHex       = StringFeatures(rawValue: 1 << 41)
    /// String looks like base64 encoding
    public static let looksLikeBase64    = StringFeatures(rawValue: 1 << 42)
    /// String looks like a UUID
    public static let looksLikeUUID      = StringFeatures(rawValue: 1 << 43)
    /// String looks like JSON
    public static let looksLikeJSON      = StringFeatures(rawValue: 1 << 44)
    /// String looks like XML/HTML
    public static let looksLikeMarkup    = StringFeatures(rawValue: 1 << 45)
    
    // MARK: - Common Patterns (bits 48-59)
    
    /// String is a common English word
    public static let isCommonWord       = StringFeatures(rawValue: 1 << 48)
    /// String looks like a person's name
    public static let looksLikeName      = StringFeatures(rawValue: 1 << 49)
    /// String has a common programming prefix
    public static let hasCommonPrefix    = StringFeatures(rawValue: 1 << 50)
    /// String has a common programming suffix
    public static let hasCommonSuffix    = StringFeatures(rawValue: 1 << 51)
    /// String looks like a programming identifier
    public static let looksLikeIdentifier = StringFeatures(rawValue: 1 << 52)
    /// String uses camelCase
    public static let isCamelCase        = StringFeatures(rawValue: 1 << 53)
    /// String uses snake_case
    public static let isSnakeCase        = StringFeatures(rawValue: 1 << 54)
    /// String uses kebab-case
    public static let isKebabCase        = StringFeatures(rawValue: 1 << 55)
    /// String contains escape sequences
    public static let containsEscapes    = StringFeatures(rawValue: 1 << 56)
    /// String looks like a constant (ALL_CAPS_WITH_UNDERSCORES)
    public static let looksLikeConstant  = StringFeatures(rawValue: 1 << 57)
    
    // MARK: - Reserved for Future Use (bits 58-63)
    
    public static let reserved58 = StringFeatures(rawValue: 1 << 58)
    public static let reserved59 = StringFeatures(rawValue: 1 << 59)
    public static let reserved60 = StringFeatures(rawValue: 1 << 60)
    public static let reserved61 = StringFeatures(rawValue: 1 << 61)
    public static let reserved62 = StringFeatures(rawValue: 1 << 62)
    public static let reserved63 = StringFeatures(rawValue: 1 << 63)
}

// MARK: - Feature Extraction

extension StringFeatures {
    /// Extract features from a string
    public static func extract(from string: String) -> StringFeatures {
        var features: StringFeatures = []
        
        // Early exit for empty strings
        if string.isEmpty {
            return .isEmpty
        }
        
        let characters = Array(string)
        let count = characters.count
        
        // Length-based features
        switch count {
        case 0:
            features.insert(.isEmpty)
        case 1:
            features.insert(.isSingleChar)
        case 2...5:
            features.insert(.isShort)
        case 6...20:
            features.insert(.isMedium)
        case 21...100:
            features.insert(.isLong)
        default:
            features.insert(.isVeryLong)
        }
        
        // Character composition analysis
        let letters = characters.filter(\.isLetter)
        let digits = characters.filter(\.isNumber)
        let uppercase = characters.filter(\.isUppercase)
        let lowercase = characters.filter(\.isLowercase)
        let whitespace = characters.filter(\.isWhitespace)
        let punctuation = characters.filter(\.isPunctuation)
        let symbols = characters.filter(\.isSymbol)
        
        // Character type features
        if letters.count == count { 
            if uppercase.count == count {
                features.insert(.isAllUppercase)
            } else if lowercase.count == count {
                features.insert(.isAllLowercase)
            }
        }
        if !uppercase.isEmpty { features.insert(.containsUppercase) }
        if !lowercase.isEmpty { features.insert(.containsLowercase) }
        if digits.count == count { features.insert(.isAllDigits) }
        if !digits.isEmpty { features.insert(.containsDigits) }
        if !whitespace.isEmpty { features.insert(.containsWhitespace) }
        if !punctuation.isEmpty { features.insert(.containsPunctuation) }
        if !symbols.isEmpty { features.insert(.containsSymbols) }
        if letters.count + digits.count == count { features.insert(.isAlphanumeric) }
        
        // ASCII/Unicode features
        if string.allSatisfy({ $0.isASCII }) {
            features.insert(.isAscii)
        } else {
            features.insert(.containsUnicode)
        }
        
        // Printable/control character features
        if characters.allSatisfy({ $0.isPrintable }) {
            features.insert(.isPrintable)
        }
        if characters.contains(where: { $0.isControlCharacter }) {
            features.insert(.containsControlChars)
        }
        
        // Structure patterns
        if hasRepeatedConsecutiveChars(characters) {
            features.insert(.hasRepeatedChars)
        }
        if Set(characters).count == 1 {
            features.insert(.isAllSameChar)
        }
        if string == String(string.reversed()) {
            features.insert(.isPalindrome)
        }
        if hasAlternatingCasePattern(characters) {
            features.insert(.hasAlternatingCase)
        }
        if characters.first?.isUppercase == true {
            features.insert(.startsWithCapital)
        }
        if characters.last?.isPunctuation == true {
            features.insert(.endsWithPunctuation)
        }
        if characters.first?.isNumber == true {
            features.insert(.startsWithDigit)
        }
        
        // Word structure
        let words = string.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count == 1 {
            features.insert(.isSingleWord)
        } else if words.count > 1 {
            features.insert(.isMultiWord)
        }
        
        // Case consistency
        if (uppercase.count == letters.count && !letters.isEmpty) || 
           (lowercase.count == letters.count && !letters.isEmpty) {
            features.insert(.hasConsistentCase)
        }
        
        // Domain-specific patterns
        if looksLikeEmailPattern(string) { features.insert(.looksLikeEmail) }
        if looksLikeURLPattern(string) { features.insert(.looksLikeURL) }
        if looksLikeFileNamePattern(string) { features.insert(.looksLikeFileName) }
        if string.contains("/") || string.contains("\\") { features.insert(.containsPath) }
        if looksLikeVersionPattern(string) { features.insert(.looksLikeVersion) }
        if looksLikeHexPattern(string) { features.insert(.looksLikeHex) }
        if looksLikeBase64Pattern(string) { features.insert(.looksLikeBase64) }
        if looksLikeUUIDPattern(string) { features.insert(.looksLikeUUID) }
        if looksLikeJSONPattern(string) { features.insert(.looksLikeJSON) }
        if looksLikeMarkupPattern(string) { features.insert(.looksLikeMarkup) }
        
        // Common patterns
        if isCommonEnglishWord(string) { features.insert(.isCommonWord) }
        if looksLikePersonName(string) { features.insert(.looksLikeName) }
        if hasCommonProgrammingPrefix(string) { features.insert(.hasCommonPrefix) }
        if hasCommonProgrammingSuffix(string) { features.insert(.hasCommonSuffix) }
        if looksLikeProgrammingIdentifier(string) { features.insert(.looksLikeIdentifier) }
        if isCamelCasePattern(string) { features.insert(.isCamelCase) }
        if isSnakeCasePattern(string) { features.insert(.isSnakeCase) }
        if isKebabCasePattern(string) { features.insert(.isKebabCase) }
        if string.contains("\\") { features.insert(.containsEscapes) }
        if looksLikeConstantPattern(string) { features.insert(.looksLikeConstant) }
        
        return features
    }
    
    /// Convert features to a binary array for machine learning
    public func toBinaryArray() -> [Int] {
        (0..<64).map { bit in
            (rawValue & (1 << bit)) != 0 ? 1 : 0
        }
    }
    
    /// Convert features to a sparse representation (indices of set bits)
    public func toSparseIndices() -> [Int] {
        (0..<64).compactMap { bit in
            (rawValue & (1 << bit)) != 0 ? bit : nil
        }
    }
}

// MARK: - Pattern Detection Helpers

private extension StringFeatures {
    static func hasRepeatedConsecutiveChars(_ chars: [Character]) -> Bool {
        for i in 0..<chars.count - 1 {
            if chars[i] == chars[i + 1] {
                return true
            }
        }
        return false
    }
    
    static func hasAlternatingCasePattern(_ chars: [Character]) -> Bool {
        guard chars.count > 1 else { return false }
        
        let letters = chars.filter(\.isLetter)
        guard letters.count > 1 else { return false }
        
        for i in 0..<letters.count - 1 {
            let current = letters[i]
            let next = letters[i + 1]
            if (current.isUppercase && next.isUppercase) || 
               (current.isLowercase && next.isLowercase) {
                return false
            }
        }
        return true
    }
    
    static func looksLikeEmailPattern(_ string: String) -> Bool {
        string.contains("@") && string.contains(".")
    }
    
    static func looksLikeURLPattern(_ string: String) -> Bool {
        string.hasPrefix("http://") || string.hasPrefix("https://") || 
        string.hasPrefix("ftp://") || string.contains("://")
    }
    
    static func looksLikeFileNamePattern(_ string: String) -> Bool {
        string.contains(".") && !string.hasPrefix(".") && !string.hasSuffix(".")
    }
    
    static func looksLikeVersionPattern(_ string: String) -> Bool {
        let pattern = #"^\d+(\.\d+)+$"#
        return string.range(of: pattern, options: .regularExpression) != nil
    }
    
    static func looksLikeHexPattern(_ string: String) -> Bool {
        guard string.count > 2 else { return false }
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return string.dropFirst(2).allSatisfy { $0.isHexDigit }
        }
        return string.count % 2 == 0 && string.allSatisfy { $0.isHexDigit }
    }
    
    static func looksLikeBase64Pattern(_ string: String) -> Bool {
        guard string.count >= 4 && string.count % 4 == 0 else { return false }
        let base64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return string.allSatisfy { base64Chars.contains($0) }
    }
    
    static func looksLikeUUIDPattern(_ string: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return string.range(of: pattern, options: .regularExpression) != nil
    }
    
    static func looksLikeJSONPattern(_ string: String) -> Bool {
        (string.hasPrefix("{") && string.hasSuffix("}")) ||
        (string.hasPrefix("[") && string.hasSuffix("]"))
    }
    
    static func looksLikeMarkupPattern(_ string: String) -> Bool {
        string.contains("<") && string.contains(">")
    }
    
    static func isCommonEnglishWord(_ string: String) -> Bool {
        let commonWords = Set(["the", "be", "to", "of", "and", "a", "in", "that", "have",
                              "it", "for", "not", "on", "with", "he", "as", "you", "do", "at"])
        return commonWords.contains(string.lowercased())
    }
    
    static func looksLikePersonName(_ string: String) -> Bool {
        let words = string.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.count >= 1 && words.count <= 3 && 
               words.allSatisfy { $0.first?.isUppercase == true && $0.dropFirst().allSatisfy(\.isLowercase) }
    }
    
    static func hasCommonProgrammingPrefix(_ string: String) -> Bool {
        let prefixes = ["get", "set", "is", "has", "can", "should", "will", "str", "num", "arr", "obj"]
        return prefixes.contains { string.lowercased().hasPrefix($0) }
    }
    
    static func hasCommonProgrammingSuffix(_ string: String) -> Bool {
        let suffixes = ["er", "ed", "ing", "tion", "able", "ful", "less", "ness", "ment"]
        return suffixes.contains { string.lowercased().hasSuffix($0) }
    }
    
    static func looksLikeProgrammingIdentifier(_ string: String) -> Bool {
        guard let first = string.first else { return false }
        return (first.isLetter || first == "_") && 
               string.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
    
    static func isCamelCasePattern(_ string: String) -> Bool {
        guard string.first?.isLowercase == true else { return false }
        return string.contains { $0.isUppercase } && !string.contains("_") && !string.contains("-")
    }
    
    static func isSnakeCasePattern(_ string: String) -> Bool {
        string.contains("_") && !string.contains { $0.isUppercase } && !string.contains("-")
    }
    
    static func isKebabCasePattern(_ string: String) -> Bool {
        string.contains("-") && !string.contains { $0.isUppercase } && !string.contains("_")
    }
    
    static func looksLikeConstantPattern(_ string: String) -> Bool {
        string.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } && 
        string.contains { $0.isLetter }
    }
}

// MARK: - Character Extensions

private extension Character {
    var isControlCharacter: Bool {
        isPrintable == false && !isWhitespace
    }
    
    var isPrintable: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
    }
}