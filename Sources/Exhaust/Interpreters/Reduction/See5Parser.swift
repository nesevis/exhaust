//
//  See5Parser.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

enum See5Parser {
    enum Op: String {
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case equal = "="
        case greaterThanOrEqual = ">="
        case greaterThan = ">"
    }
    
    struct RuleElement {
        let label: String
        let op: Op
        let value: String
    }
    
    struct Rule {
        let number: Int
        let occurrences: Int
        let lift: Double
        let elements: [RuleElement]
        let pass: Bool
        let confidence: Double
        
        static func parse(source: inout String.SubSequence) -> Rule? {
            guard source.hasPrefix("Rule") else {
                return nil
            }
            /*
             Rules:
             Rule 1: (16, lift 3.0)
                 pick_d1 = false
                 sequence_d1 <= 49
                 ->  class pass  [0.944]
             Rule 2: (23, lift 1.4)
                 pick_d1 = true
                 ->  class fail  [0.960]
             Rule 3: (17, lift 1.4)
                 sequence_d1 > 49
                 ->  class fail  [0.947]
             */
            var data = source.prefix(while: { $0 != "]" })
                .dropFirst(5) // "Rule "
            var dataCount = data.count + 5 + 1 // ]
            let ruleNumberString = String(data.prefix(while: \.isNumber))
            let ruleNumber = Int(ruleNumberString)
            data = data.dropFirst(ruleNumberString.count + 3) // ": ("
            let occurrencesString = String(data.prefix(while: \.isNumber))
            let occurrences = Int(occurrencesString)
            data = data.dropFirst(occurrencesString.count + 7) // ", lift "
            let liftString = String(data.prefix(while: { $0 != ")" }))
            let lift = Double(liftString)
            data = data.dropFirst(liftString.count + 2) // ")\n"
            data = data.drop(while: \.isWhitespace) // Tabs
            
            // sequence_d1 > 49
            func parseRuleElement(source: inout String.SubSequence) -> RuleElement? {
                guard source.hasPrefix("->") == false else {
                    return nil
                }
                var data = source
                data = data.drop(while: \.isWhitespace)
                let label = String(data.prefix(while: { $0.isWhitespace == false }))
                data = data.dropFirst(label.count + 1) // space
                let opString = String(data.prefix(while: { $0.isWhitespace == false }))
                let op = Op(rawValue: opString)
                data = data.dropFirst(opString.count + 1) // space
                let value = String(data.prefix(while: { $0.isNewline == false }))
                data = data.dropFirst(value.count + 1) // newline
                guard let op else {
                    return nil
                }
                source = source.dropFirst(source.count - data.count)
                return .init(label: label, op: op, value: value)
            }
            
            var elements = [RuleElement]()
            while let element = parseRuleElement(source: &data) {
                elements.append(element)
            }
            data = data.drop(while: \.isWhitespace)
            data = data.dropFirst(10) // "->  class  "
            let passFail = data.prefix(4)
            let pass = passFail == "pass"
            data = data.dropFirst(7) // "pass|fail  ["
            
            let confidenceString = data.prefix(while: { $0.isNumber || $0.isPunctuation })
            let confidence = Double(confidenceString)
            data = data.dropFirst(confidenceString.count + 1) // newline
            
            guard
                let ruleNumber,
                let occurrences,
                let lift,
                let confidence
            else {
                return nil
            }
            let rule = Rule(
                number: ruleNumber,
                occurrences: occurrences,
                lift: lift,
                elements: elements,
                pass: pass,
                confidence: confidence
            )
            
            source = source.dropFirst(dataCount + 1) // Newline
            return rule
        }
    }
    
    static func parse(source: inout String.SubSequence) -> [Rule] {
        let droppedPreamble = source.split(separator: "\n").dropFirst(8).joined(separator: "\n")
        var rules = [Rule]()
        var mutablePreamble = droppedPreamble[...]
        while let rule = Rule.parse(source: &mutablePreamble) {
            rules.append(rule)
        }
        source = mutablePreamble
        return rules
    }
    
    /*
     C5.0 [Release 2.07 GPL Edition]      Mon Aug  4 22:08:35 2025
     -------------------------------
         Options:
         Application `/var/folders/9j/9mmq088d5sqbhbhv4rdbg7tc0000gn/T/c50_E139547D-8477-4527-BCA6-545362394E04/data'
         Rule-based classifiers
         Pruning confidence level 25%
     Read 51 cases (3 attributes) from /var/folders/9j/9mmq088d5sqbhbhv4rdbg7tc0000gn/T/c50_E139547D-8477-4527-BCA6-545362394E04/data.data
     Rules:
     Rule 1: (16, lift 3.0)
         pick_d1 = false
         sequence_d1 <= 49
         ->  class pass  [0.944]
     Rule 2: (23, lift 1.4)
         pick_d1 = true
         ->  class fail  [0.960]
     Rule 3: (17, lift 1.4)
         sequence_d1 > 49
         ->  class fail  [0.947]
     Default class: fail
     Evaluation on training data (51 cases):
                 Rules
           ----------------
             No      Errors
              3    0( 0.0%)   <<
            (a)   (b)    <-classified as
           ----  ----
             16          (a): class pass
                   35    (b): class fail
         Attribute usage:
              76%  pick_d1
              65%  sequence_d1
     Time: 0.0 secs
     */
}

