import Foundation

public enum RuleBasedWorkoutParser {
    /// Deterministic, zero-latency workout utterance parser used both as an instant fallback
    /// when the local LLM is unavailable and as a structured sanity check on gym commands.
    public static func parse(
        _ transcript: String,
        context: ActiveSessionPromptContext = ActiveSessionPromptContext()
    ) -> WorkoutCommandIntent {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return unknownIntent(rawTranscript: transcript)
        }

        let normalized = normalizeTranscript(trimmed)
        guard !normalized.isEmpty else {
            return unknownIntent(rawTranscript: transcript)
        }

        // 1. Voice session control & undo/edit commands (ordered by specificity)
        if isEndSessionCommand(normalized) {
            return WorkoutCommandIntent(
                action: .endSession,
                items: [],
                summary: "End workout",
                rawTranscript: transcript,
                parserSource: .ruleBased
            )
        }

        if isDeleteLastExerciseCommand(normalized) {
            return WorkoutCommandIntent(
                action: .deleteLastExercise,
                items: [],
                summary: "Delete last exercise",
                rawTranscript: transcript,
                parserSource: .ruleBased
            )
        }

        if isDeleteLastSetCommand(normalized) {
            return WorkoutCommandIntent(
                action: .deleteLastSet,
                items: [],
                summary: "Delete last set",
                rawTranscript: transcript,
                parserSource: .ruleBased
            )
        }

        if let updateIntent = parseUpdateLastSet(
            normalized: normalized,
            rawTranscript: transcript,
            context: context
        ) {
            return updateIntent
        }

        // 2. Strength / timed / cardio logging (supports single or chained clauses)
        let clauses = splitIntoClauses(normalized)
        var parsedItems: [ParsedSetGroupIntent] = []
        var rollingLastExercise = context.lastExerciseName

        for clause in clauses {
            let clauseContext = ActiveSessionPromptContext(
                preferredUnit: context.preferredUnit,
                lastExerciseName: rollingLastExercise,
                recentExercisesInSession: context.recentExercisesInSession,
                isSessionActive: context.isSessionActive
            )
            if let item = parseSetGroupClause(clause, context: clauseContext) {
                parsedItems.append(item)
                rollingLastExercise = item.exerciseName
            }
        }

        // If clause splitting failed to produce items on a multi-part string, retry whole utterance
        if parsedItems.isEmpty && clauses.count > 1,
           let singleItem = parseSetGroupClause(normalized, context: context) {
            parsedItems = [singleItem]
        }

        guard !parsedItems.isEmpty else {
            return unknownIntent(rawTranscript: transcript)
        }

        let summary = buildLogSummary(items: parsedItems, defaultUnit: context.preferredUnit)
        return WorkoutCommandIntent(
            action: .logSets,
            items: parsedItems,
            summary: summary,
            rawTranscript: transcript,
            parserSource: .ruleBased
        )
    }

    // MARK: - Normalization & Number Words

    private static let onesWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]

    private static let teensWords: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    private static let preserveOneBeforeWords: Set<String> = [
        "arm", "armed", "leg", "legged", "hand", "handed", "sided"
    ]

    private static let colloquialHundredTeenFollowers: Set<String> = [
        "kg", "kgs", "kilo", "kilos", "kilogram", "kilograms",
        "lb", "lbs", "pound", "pounds",
        "for", "rep", "reps", "set", "sets", "x", "by"
    ]

    private static func isNumberWord(_ word: String) -> Bool {
        word == "zero" || word == "hundred" ||
        onesWords[word] != nil || teensWords[word] != nil || tensWords[word] != nil
    }

    private static func normalizeTranscript(_ raw: String) -> String {
        var text = raw
            .lowercased()
            .replacingOccurrences(of: "\u{00D7}", with: " x ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2014}", with: " ")
            .replacingOccurrences(of: "\u{2013}", with: "-")

        // Friendly spoken duration idioms before number normalization
        text = replaceMatches(
            pattern: #"\b(?:a|one|1)\s+minute\s+and\s+a\s+half\b"#,
            in: text,
            with: "1 minute 30 seconds"
        )
        text = replaceMatches(
            pattern: #"\bhalf\s+an?\s+hour\b"#,
            in: text,
            with: "30 minutes"
        )
        text = replaceMatches(
            pattern: #"\b(?:a|an)\s+(minute|min|second|sec|hour)\b"#,
            in: text,
            with: "1 $1"
        )
        text = replaceMatches(
            pattern: #"(?<![a-z])k\.\s*g\.?(?![a-z])"#,
            in: text,
            with: "kg"
        )
        text = replaceMatches(
            pattern: #"(?<![a-z])k\s+g(?![a-z])"#,
            in: text,
            with: "kg"
        )
        text = replaceMatches(
            pattern: #"(?<![a-z])lbs?\.(?![a-z])"#,
            in: text,
            with: "lbs"
        )
        text = replaceMatches(
            pattern: #"(?<![a-z])lb(?![a-z])"#,
            in: text,
            with: "lbs"
        )

        text = normalizeNumberWords(in: text)

        // Spoken decimal numbers: "22 point 5" -> "22.5"
        text = replaceMatches(pattern: #"(\d+)\s+point\s+(\d+)"#, in: text, with: "$1.$2")
        // Spoken half weights: "22 and a half kg" -> "22.5 kg"
        text = replaceMatches(
            pattern: #"(\d+)\s+and\s+a\s+half\s*(kg|kgs|kilos?|kilograms?|lbs?|pounds?)\b"#,
            in: text,
            with: "$1.5 $2"
        )

        return collapseWhitespace(text)
    }

    private static func normalizeNumberWords(in text: String) -> String {
        // Tokenize and split hyphenated compound number words like "forty-five" -> ["forty", "five"]
        let rawTokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var tokens: [String] = []
        tokens.reserveCapacity(rawTokens.count + 4)

        for token in rawTokens {
            let (lead, core, trail) = splitPunctuation(token)
            if core.contains("-") {
                let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 && isNumberWord(parts[0]) && isNumberWord(parts[1]) {
                    tokens.append(lead + parts[0])
                    tokens.append(parts[1] + trail)
                    continue
                }
            }
            tokens.append(token)
        }

        var output: [String] = []
        output.reserveCapacity(tokens.count)
        var i = 0

        while i < tokens.count {
            let (lead, core, trail) = splitPunctuation(tokens[i])

            // Preserve phrases like "one arm dumbbell row" or "one leg press"
            if core == "one", i + 1 < tokens.count {
                let (_, nextCore, _) = splitPunctuation(tokens[i + 1])
                if preserveOneBeforeWords.contains(nextCore) {
                    output.append(tokens[i])
                    i += 1
                    continue
                }
            }

            // "a hundred [and] ..."
            if core == "a", trail.isEmpty, i + 1 < tokens.count {
                let (nextLead, nextCore, nextTrail) = splitPunctuation(tokens[i + 1])
                if nextLead.isEmpty && nextCore == "hundred" {
                    var value = 100
                    var finalTrail = nextTrail
                    i += 2
                    if finalTrail.isEmpty {
                        let consumed = consumeSubHundred(tokens: tokens, startIndex: i)
                        value += consumed.addedValue
                        i = consumed.nextIndex
                        if !consumed.trailingPunctuation.isEmpty {
                            finalTrail = consumed.trailingPunctuation
                        }
                    }
                    output.append("\(lead)\(value)\(finalTrail)")
                    continue
                }
            }

            if core == "zero" {
                output.append("\(lead)0\(trail)")
                i += 1
                continue
            }

            if core == "hundred" {
                var value = 100
                var finalTrail = trail
                i += 1
                if finalTrail.isEmpty {
                    let consumed = consumeSubHundred(tokens: tokens, startIndex: i)
                    value += consumed.addedValue
                    i = consumed.nextIndex
                    if !consumed.trailingPunctuation.isEmpty {
                        finalTrail = consumed.trailingPunctuation
                    }
                }
                output.append("\(lead)\(value)\(finalTrail)")
                continue
            }

            if let onesVal = onesWords[core] {
                if trail.isEmpty, i + 1 < tokens.count {
                    let (nextLead, nextCore, nextTrail) = splitPunctuation(tokens[i + 1])
                    if nextLead.isEmpty && nextCore == "hundred" {
                        var value = onesVal * 100
                        var finalTrail = nextTrail
                        i += 2
                        if finalTrail.isEmpty {
                            let consumed = consumeSubHundred(tokens: tokens, startIndex: i)
                            value += consumed.addedValue
                            i = consumed.nextIndex
                            if !consumed.trailingPunctuation.isEmpty {
                                finalTrail = consumed.trailingPunctuation
                            }
                        }
                        output.append("\(lead)\(value)\(finalTrail)")
                        continue
                    }

                    // Colloquial 3-digit gym weights without "hundred":
                    // e.g. "one thirty five" -> 135, "two twenty five" -> 225, "one eighty" -> 180.
                    if nextLead.isEmpty, let tensVal = tensWords[nextCore] {
                        var value = onesVal * 100 + tensVal
                        var finalTrail = nextTrail
                        i += 2
                        if finalTrail.isEmpty, i < tokens.count {
                            let (thirdLead, thirdCore, thirdTrail) = splitPunctuation(tokens[i])
                            if thirdLead.isEmpty, let trailingOnes = onesWords[thirdCore] {
                                value += trailingOnes
                                finalTrail = thirdTrail
                                i += 1
                            }
                        }
                        output.append("\(lead)\(value)\(finalTrail)")
                        continue
                    }

                    // Colloquial plate weights like "one oh five" (105) or "four oh five" (405).
                    if nextLead.isEmpty, nextTrail.isEmpty,
                       (nextCore == "oh" || nextCore == "zero"),
                       i + 2 < tokens.count {
                        let (thirdLead, thirdCore, thirdTrail) = splitPunctuation(tokens[i + 2])
                        if thirdLead.isEmpty, let trailingOnes = onesWords[thirdCore] {
                            let value = onesVal * 100 + trailingOnes
                            output.append("\(lead)\(value)\(thirdTrail)")
                            i += 3
                            continue
                        }
                    }

                    // Colloquial 3-digit teen weights like "three fifteen for five" (315) or "two fifteen lbs",
                    // while preserving bare set/rep shorthand like "leg extension three fifteen" -> "3 15".
                    if nextLead.isEmpty, let teensVal = teensWords[nextCore], i + 2 < tokens.count {
                        let (_, afterCore, _) = splitPunctuation(tokens[i + 2])
                        let followedByWeightOrReps = colloquialHundredTeenFollowers.contains(afterCore)
                            || (afterCore.range(of: #"^\d+x\d+$"#, options: .regularExpression) != nil)
                        if followedByWeightOrReps {
                            let value = onesVal * 100 + teensVal
                            output.append("\(lead)\(value)\(nextTrail)")
                            i += 2
                            continue
                        }
                    }
                }
                output.append("\(lead)\(onesVal)\(trail)")
                i += 1
                continue
            }

            if let tensVal = tensWords[core] {
                var value = tensVal
                var finalTrail = trail
                i += 1
                if finalTrail.isEmpty, i < tokens.count {
                    let (nextLead, nextCore, nextTrail) = splitPunctuation(tokens[i])
                    if nextLead.isEmpty, let onesVal = onesWords[nextCore] {
                        value += onesVal
                        finalTrail = nextTrail
                        i += 1
                    }
                }
                output.append("\(lead)\(value)\(finalTrail)")
                continue
            }

            if let teensVal = teensWords[core] {
                output.append("\(lead)\(teensVal)\(trail)")
                i += 1
                continue
            }

            output.append(tokens[i])
            i += 1
        }

        return output.joined(separator: " ")
    }

    private static func consumeSubHundred(
        tokens: [String],
        startIndex: Int
    ) -> (addedValue: Int, nextIndex: Int, trailingPunctuation: String) {
        guard startIndex < tokens.count else { return (0, startIndex, "") }

        let (_, maybeAnd, andTrail) = splitPunctuation(tokens[startIndex])
        if maybeAnd == "and" && andTrail.isEmpty && startIndex + 1 < tokens.count {
            let candidate = consumeSubHundredDirect(tokens: tokens, startIndex: startIndex + 1)
            if candidate.addedValue > 0 {
                return candidate
            }
            return (0, startIndex, "")
        }

        return consumeSubHundredDirect(tokens: tokens, startIndex: startIndex)
    }

    private static func consumeSubHundredDirect(
        tokens: [String],
        startIndex: Int
    ) -> (addedValue: Int, nextIndex: Int, trailingPunctuation: String) {
        guard startIndex < tokens.count else { return (0, startIndex, "") }
        let (lead, core, trail) = splitPunctuation(tokens[startIndex])
        guard lead.isEmpty else { return (0, startIndex, "") }

        if let tensVal = tensWords[core] {
            var value = tensVal
            var nextIdx = startIndex + 1
            var finalTrail = trail
            if finalTrail.isEmpty, nextIdx < tokens.count {
                let (nextLead, nextCore, nextTrail) = splitPunctuation(tokens[nextIdx])
                if nextLead.isEmpty, let onesVal = onesWords[nextCore] {
                    value += onesVal
                    finalTrail = nextTrail
                    nextIdx += 1
                }
            }
            return (value, nextIdx, finalTrail)
        }

        if let teensVal = teensWords[core] {
            return (teensVal, startIndex + 1, trail)
        }

        if let onesVal = onesWords[core] {
            return (onesVal, startIndex + 1, trail)
        }

        return (0, startIndex, "")
    }

    private static func splitPunctuation(_ token: String) -> (leading: String, core: String, trailing: String) {
        let punct = CharacterSet(charactersIn: ",.!?;:()[]\"'")
        var start = token.startIndex
        while start < token.endIndex,
              let scalar = token[start].unicodeScalars.first,
              token[start].unicodeScalars.count == 1,
              punct.contains(scalar) {
            start = token.index(after: start)
        }
        var end = token.endIndex
        while end > start {
            let prev = token.index(before: end)
            if let scalar = token[prev].unicodeScalars.first,
               token[prev].unicodeScalars.count == 1,
               punct.contains(scalar) {
                end = prev
            } else {
                break
            }
        }
        return (String(token[..<start]), String(token[start..<end]), String(token[end...]))
    }

    // MARK: - Voice Control / Undo / Edit Commands

    private static func isEndSessionCommand(_ text: String) -> Bool {
        let patterns = [
            #"\b(?:end|finish|stop|complete|close|wrap\s+up)\s+(?:the\s+|my\s+|this\s+)?(?:workout|session)\b"#,
            #"\b(?:i'?m\s+|im\s+)?(?:done|finished)\s+(?:working\s+out|with\s+(?:the\s+|my\s+)?(?:workout|session))\b"#,
            #"\b(?:workout|session)\s+(?:is\s+)?(?:done|finished|complete|over)\b"#
        ]
        return patterns.contains { firstMatch(pattern: $0, in: text) != nil }
    }

    private static func isDeleteLastExerciseCommand(_ text: String) -> Bool {
        let patterns = [
            #"\b(?:delete|remove|undo|clear|cancel|erase)\s+(?:the\s+|my\s+)?(?:last|previous|latest|recent|that)\s+(?:exercise|movement|entry|lift)\b"#,
            #"^(?:delete|remove|undo|clear)\s+(?:the\s+)?(?:exercise|movement)$"#
        ]
        return patterns.contains { firstMatch(pattern: $0, in: text) != nil }
    }

    private static func isDeleteLastSetCommand(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let exactCommands: Set<String> = [
            "undo", "undo that", "undo last", "delete last", "remove last",
            "scratch that", "never mind", "nevermind"
        ]
        if exactCommands.contains(stripped) {
            return true
        }
        let patterns = [
            #"\b(?:delete|remove|undo|clear|cancel|erase|scratch)\s+(?:the\s+|my\s+)?(?:last|previous|latest|recent|that)\s+(?:set|log|one)\b"#,
            #"^(?:delete|remove|undo)\s+(?:the\s+)?set$"#
        ]
        return patterns.contains { firstMatch(pattern: $0, in: stripped) != nil }
    }

    private static func parseUpdateLastSet(
        normalized: String,
        rawTranscript: String,
        context: ActiveSessionPromptContext
    ) -> WorkoutCommandIntent? {
        let triggerPattern = #"^(?:(?:actually\s+|wait\s+|sorry\s+|correction\s+)?(?:(?:change|update|edit|fix|modify|correct|set|mark|tag)\s+(?:the\s+|my\s+)?(?:last\s+set|previous\s+set|that\s+set|that|it)|make\s+(?:the\s+|my\s+)?(?:last\s+set|previous\s+set|that\s+set|that|it)|(?:mark|tag)\s+(?:as\s+)?(?=(?:to\s+failure|failure|drop\s*set|dropset|warm\s*up|warmup|working|normal))|actually\s+(?:that|it)\s+was|actually\s+(?=\d)))\b(.*)$"#

        guard let match = firstMatch(pattern: triggerPattern, in: normalized),
              var remainder = captureGroup(1, in: match, text: normalized) else {
            return nil
        }

        // Remove optional leading "to" / "as" / "a"
        remainder = replaceMatches(pattern: #"^\s*(?:to|as|into|=)\b"#, in: remainder, with: " ")
        remainder = replaceMatches(pattern: #"^\s*(?:a|an)\b"#, in: remainder, with: " ")

        var tag: SetTag = .normal
        var explicitNormalTag = false
        var durationSeconds: Int?
        var weightValue: Double?
        var weightUnit: WeightUnit?
        var reps: Int?

        // Extract tag
        if let tagMatch = firstMatch(pattern: #"\b(?:to\s+failure|till\s+failure|until\s+failure|failure\s+sets?|failure)\b"#, in: remainder) {
            tag = .failure
            remainder = removingMatch(tagMatch, from: remainder)
        } else if let tagMatch = firstMatch(pattern: #"\b(?:drop\s*sets?|dropsets?)\b"#, in: remainder) {
            tag = .dropset
            remainder = removingMatch(tagMatch, from: remainder)
        } else if let tagMatch = firstMatch(pattern: #"\b(?:warm\s*up\s+sets?|warm\s*ups?|warmups?)\b"#, in: remainder) {
            tag = .warmup
            remainder = removingMatch(tagMatch, from: remainder)
        } else if let tagMatch = firstMatch(pattern: #"\b(?:working\s+sets?|normal\s+sets?|working|normal)\b"#, in: remainder) {
            tag = .normal
            explicitNormalTag = true
            remainder = removingMatch(tagMatch, from: remainder)
        }

        // Extract duration
        let durResult = extractDuration(from: remainder)
        durationSeconds = durResult.seconds
        remainder = durResult.remaining

        // Extract explicit weight with unit
        let weightResult = extractWeight(from: remainder)
        weightValue = weightResult.value
        weightUnit = weightResult.unit
        remainder = weightResult.remaining

        // Extract "weight [to] N" without explicit unit (falls back to user preferred unit)
        if weightValue == nil,
           let wMatch = firstMatch(pattern: #"\bweight\s+(?:to\s+)?(\d+(?:\.\d+)?)\b"#, in: remainder),
           let numStr = captureGroup(1, in: wMatch, text: remainder),
           let parsedWeight = Double(numStr), parsedWeight > 0 {
            weightValue = parsedWeight
            weightUnit = nil
            remainder = removingMatch(wMatch, from: remainder)
        }

        // Extract explicit reps ("12 reps" or "reps [to] 12")
        if let rMatch = firstMatch(pattern: #"\b(\d{1,3})\s+reps?\b"#, in: remainder),
           let numStr = captureGroup(1, in: rMatch, text: remainder),
           let parsedReps = Int(numStr), parsedReps > 0 {
            reps = parsedReps
            remainder = removingMatch(rMatch, from: remainder)
        } else if let rMatch = firstMatch(pattern: #"\breps?\s+(?:to\s+)?(\d{1,3})\b"#, in: remainder),
                  let numStr = captureGroup(1, in: rMatch, text: remainder),
                  let parsedReps = Int(numStr), parsedReps > 0 {
            reps = parsedReps
            remainder = removingMatch(rMatch, from: remainder)
        }

        // Bare unitless number after "make that 50" / "change last set to 85" -> resolve as weight in preferred unit.
        if weightValue == nil && reps == nil && durationSeconds == nil {
            let trimmedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if let bareMatch = firstMatch(pattern: #"^(?:at\s+)?(\d+(?:\.\d+)?)$"#, in: trimmedRemainder),
               let numStr = captureGroup(1, in: bareMatch, text: trimmedRemainder),
               let parsedWeight = Double(numStr), parsedWeight > 0 {
                weightValue = parsedWeight
                weightUnit = nil
            }
        }

        let hasAnyMutation = reps != nil || weightValue != nil || durationSeconds != nil || tag != .normal || explicitNormalTag
        guard hasAnyMutation else {
            return nil
        }

        let item = ParsedSetGroupIntent(
            exerciseName: context.lastExerciseName ?? "",
            setCount: 1,
            reps: reps,
            weightValue: weightValue,
            weightUnit: weightUnit,
            durationSeconds: durationSeconds,
            tag: tag,
            hasExplicitTag: tag != .normal || explicitNormalTag,
            note: ""
        )

        var detailParts: [String] = []
        if let weightValue {
            let unit = weightUnit ?? context.preferredUnit
            detailParts.append(formatWeightValue(weightValue, unit: unit))
        }
        if let reps {
            detailParts.append("\(reps) reps")
        }
        if let durationSeconds {
            detailParts.append(DurationFormatter.formatCompact(seconds: durationSeconds))
        }
        if tag != .normal {
            detailParts.append(tag.displayLabel)
        } else if explicitNormalTag {
            detailParts.append("Working")
        }

        let summary = "Update last set → \(detailParts.joined(separator: " · "))"
        return WorkoutCommandIntent(
            action: .updateLastSet,
            items: [item],
            summary: summary,
            rawTranscript: rawTranscript,
            parserSource: .ruleBased
        )
    }

    // MARK: - Clause Splitting & Set Group Parsing

    private static func splitIntoClauses(_ normalized: String) -> [String] {
        let separatorPattern = #"(?:\s*;\s*|\s+and\s+then\s+|\s+then\s+)"#
        let replaced = replaceMatches(pattern: separatorPattern, in: normalized, with: " || ")
        let primaryParts = replaced
            .components(separatedBy: " || ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Also split on plain " and " ONLY when both halves contain workout metrics (digits),
        // preserving compound exercise names like "clean and jerk" or "snatch and press".
        var finalParts: [String] = []
        for part in primaryParts {
            let subParts = part
                .components(separatedBy: " and ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if subParts.count > 1 && subParts.allSatisfy({ firstMatch(pattern: #"\d"#, in: $0) != nil }) {
                finalParts.append(contentsOf: subParts)
            } else {
                finalParts.append(part)
            }
        }

        return finalParts.isEmpty ? [normalized] : finalParts
    }

    private static func parseSetGroupClause(
        _ clause: String,
        context: ActiveSessionPromptContext
    ) -> ParsedSetGroupIntent? {
        var working = clause
        var tag: SetTag = .normal
        var setCount: Int?
        var explicitSetsMentioned = false
        var reps: Int?
        var weightValue: Double?
        var weightUnit: WeightUnit?
        var durationSeconds: Int?

        // 1. Extract tags (handle counted tag sets like "2 drop sets" or "2 warm ups" first)
        if let m = firstMatch(pattern: #"\b(\d{1,2})\s+(?:drop\s*sets?|dropsets?)\b"#, in: working),
           let countStr = captureGroup(1, in: m, text: working),
           let count = Int(countStr), (1...30).contains(count) {
            tag = .dropset
            setCount = count
            explicitSetsMentioned = true
            working = removingMatch(m, from: working)
        } else if let m = firstMatch(pattern: #"\b(?:drop\s*sets?|dropsets?)\b"#, in: working) {
            tag = .dropset
            working = removingMatch(m, from: working)
        }

        if let m = firstMatch(pattern: #"\b(\d{1,2})\s+(?:warm\s*up\s+sets?|warm\s*ups?|warmups?)\b"#, in: working),
           let countStr = captureGroup(1, in: m, text: working),
           let count = Int(countStr), (1...30).contains(count) {
            tag = .warmup
            if setCount == nil {
                setCount = count
                explicitSetsMentioned = true
            }
            working = removingMatch(m, from: working)
        } else if let m = firstMatch(pattern: #"\b(?:warm\s*up\s+sets?|warm\s*ups?|warmups?|warming\s+up)\b"#, in: working) {
            tag = .warmup
            working = removingMatch(m, from: working)
        }

        if let m = firstMatch(pattern: #"\b(?:to\s+failure|till\s+failure|until\s+failure|failure\s+sets?|failure)\b"#, in: working) {
            tag = .failure
            working = removingMatch(m, from: working)
        }

        // 2. Extract duration (timed / cardio exercises)
        let durResult = extractDuration(from: working)
        durationSeconds = durResult.seconds
        working = durResult.remaining

        // 3. Extract weight + explicit unit (kg / lbs)
        let weightResult = extractWeight(from: working)
        weightValue = weightResult.value
        weightUnit = weightResult.unit
        working = weightResult.remaining

        // Strip "bodyweight" / "body weight" marker so exercise resolves cleanly
        if let bwMatch = firstMatch(pattern: #"\b(?:body\s*weight|bw)\b"#, in: working) {
            working = removingMatch(bwMatch, from: working)
        }

        // 4. Extract "sets x reps" or "sets by reps" shorthand (e.g. "3x10", "3 x 10", "5 by 5")
        if let m = firstMatch(pattern: #"\b(\d{1,2})\s*(?:x|by)\s*(\d{1,3})\b"#, in: working),
           let sStr = captureGroup(1, in: m, text: working),
           let rStr = captureGroup(2, in: m, text: working),
           let s = Int(sStr), let r = Int(rStr),
           (1...30).contains(s), (1...500).contains(r) {
            setCount = s
            reps = r
            explicitSetsMentioned = true
            working = removingMatch(m, from: working)
        }

        // 5. Extract explicit "N set(s) [of] M [reps]" (e.g. "3 set 15 reps", "3 sets of 15")
        if reps == nil,
           let m = firstMatch(pattern: #"\b(\d{1,2})\s+sets?\s+(?:of\s+)?(\d{1,3})(?:\s+reps?)?\b"#, in: working),
           let sStr = captureGroup(1, in: m, text: working),
           let rStr = captureGroup(2, in: m, text: working),
           let s = Int(sStr), let r = Int(rStr),
           (1...30).contains(s), (1...500).contains(r) {
            setCount = s
            reps = r
            explicitSetsMentioned = true
            working = removingMatch(m, from: working)
        }

        // 6. Extract continuation patterns ("another set [of N [reps]]", "1 more set [of N]")
        if let m = firstMatch(
            pattern: #"\b(?:another|1\s+more|one\s+more)\s+set(?:\s+(?:of\s+)?(\d{1,3})(?:\s+reps?)?)?\b"#,
            in: working
        ) {
            if setCount == nil {
                setCount = 1
                explicitSetsMentioned = true
            }
            if reps == nil,
               let rStr = captureGroup(1, in: m, text: working),
               let r = Int(rStr), (1...500).contains(r) {
                reps = r
            }
            working = removingMatch(m, from: working)
        }

        // 7. Extract standalone explicit sets ("3 sets", "2 more sets")
        if setCount == nil,
           let m = firstMatch(pattern: #"\b(\d{1,2})\s+(?:more\s+)?sets?\b"#, in: working),
           let sStr = captureGroup(1, in: m, text: working),
           let s = Int(sStr), (1...30).contains(s) {
            setCount = s
            explicitSetsMentioned = true
            working = removingMatch(m, from: working)
        }

        // 8. Extract standalone explicit reps ("15 reps", "8 rep")
        if reps == nil,
           let m = firstMatch(pattern: #"\b(\d{1,3})\s+reps?\b"#, in: working),
           let rStr = captureGroup(1, in: m, text: working),
           let r = Int(rStr), (1...500).contains(r) {
            reps = r
            working = removingMatch(m, from: working)
        }

        // 9. Extract implicit reps via "for N" / "of N" (e.g. "bench press 135 lbs for 8", "set of 12")
        if reps == nil && durationSeconds == nil,
           let m = firstMatch(
               pattern: #"\b(?:for|of)\s+(\d{1,3})\b(?!\s*(?:degree|deg|incline|percent|%))"#,
               in: working
           ),
           let rStr = captureGroup(1, in: m, text: working),
           let r = Int(rStr), (1...500).contains(r) {
            reps = r
            working = removingMatch(m, from: working)
        }

        // 10. Bare trailing numbers when metrics are partially present (e.g. "bench press 60 kg 10" or "leg extension 3 15")
        if reps == nil && durationSeconds == nil {
            if weightValue != nil,
               let m = firstMatch(
                   pattern: #"\b(\d{1,3})\b(?!\s*(?:degree|deg|incline|percent|%))\s*$"#,
                   in: working
               ),
               let rStr = captureGroup(1, in: m, text: working),
               let r = Int(rStr), (1...200).contains(r) {
                reps = r
                working = removingMatch(m, from: working)
            } else if setCount == nil,
                      let m = firstMatch(
                          pattern: #"\b(\d{1,2})\s+(\d{1,3})\b(?!\s*(?:degree|deg|incline|percent|%))\s*$"#,
                          in: working
                      ),
                      let sStr = captureGroup(1, in: m, text: working),
                      let rStr = captureGroup(2, in: m, text: working),
                      let s = Int(sStr), let r = Int(rStr),
                      (1...20).contains(s), (1...200).contains(r) {
                setCount = s
                reps = r
                explicitSetsMentioned = true
                working = removingMatch(m, from: working)
            }
        }

        // 10b. Unitless weight when reps/sets are already extracted (e.g., "bench press 3x10 at 80" or "bench press 135 3x8")
        if weightValue == nil && (reps != nil || explicitSetsMentioned) {
            if let m = firstMatch(
                pattern: #"\b(?:at|with|@)\s+(\d+(?:\.\d+)?)\b(?!\s*(?:degree|deg|incline|percent|%))"#,
                in: working
            ),
               let numStr = captureGroup(1, in: m, text: working),
               let parsed = Double(numStr), parsed >= 2.5, parsed <= 1500 {
                weightValue = parsed
                weightUnit = nil
                working = removingMatch(m, from: working)
            } else if let m = firstMatch(
                pattern: #"\b(\d+(?:\.\d+)?)\b(?!\s*(?:degree|deg|incline|percent|%))\s*$"#,
                in: working
            ),
               let numStr = captureGroup(1, in: m, text: working),
               let parsed = Double(numStr), parsed >= 2.5, parsed <= 1500 {
                weightValue = parsed
                weightUnit = nil
                working = removingMatch(m, from: working)
            }
        }

        let hasAnyMetric = reps != nil || weightValue != nil || durationSeconds != nil || explicitSetsMentioned
        guard hasAnyMetric else {
            return nil
        }

        // 11. Clean remaining tokens to isolate exercise name (or inherit last exercise)
        let cleanedExercise = cleanExerciseName(working)
        let finalExerciseName: String

        if cleanedExercise.isEmpty || isContinuationPhrase(cleanedExercise) {
            guard let inherited = context.lastExerciseName,
                  !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            finalExerciseName = ExerciseCatalog.resolve(inherited).displayName
        } else {
            finalExerciseName = ExerciseCatalog.resolve(cleanedExercise).displayName
        }

        return ParsedSetGroupIntent(
            exerciseName: finalExerciseName,
            setCount: max(1, setCount ?? 1),
            reps: reps,
            weightValue: weightValue,
            weightUnit: weightUnit,
            durationSeconds: durationSeconds,
            tag: tag,
            note: ""
        )
    }

    // MARK: - Metric Extractors

    private static func extractDuration(from input: String) -> (seconds: Int?, remaining: String) {
        var working = input
        var totalSeconds = 0
        var found = false

        // Clock notation "1:30"
        let clockMatches = allMatches(pattern: #"\b(\d{1,2}):(\d{2})\b"#, in: working)
        for m in clockMatches.reversed() {
            if let minsStr = captureGroup(1, in: m, text: working),
               let secsStr = captureGroup(2, in: m, text: working),
               let mins = Int(minsStr), let secs = Int(secsStr), secs < 60 {
                totalSeconds += mins * 60 + secs
                found = true
                working = removingMatch(m, from: working)
            }
        }

        // Hours
        let hourMatches = allMatches(
            pattern: #"(?:(?:for)\s+)?(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\b"#,
            in: working
        )
        for m in hourMatches.reversed() {
            if let valStr = captureGroup(1, in: m, text: working),
               let val = Double(valStr), val > 0 {
                totalSeconds += Int((val * 3600.0).rounded())
                found = true
                working = removingMatch(m, from: working)
            }
        }

        // "1 minute 30" (implicit seconds immediately following minutes)
        let minImplicitSecMatches = allMatches(
            pattern: #"(?:(?:for)\s+)?(\d+)\s*(?:minutes?|mins?)\s+(?:and\s+)?(\d{1,2})\b(?!\s*(?:kg|kgs|kilos?|kilograms?|lbs?|pounds?|reps?|sets?|x|by|seconds?|secs?|minutes?|mins?))"#,
            in: working
        )
        for m in minImplicitSecMatches.reversed() {
            if let minsStr = captureGroup(1, in: m, text: working),
               let secsStr = captureGroup(2, in: m, text: working),
               let mins = Int(minsStr), let secs = Int(secsStr), secs < 60 {
                totalSeconds += mins * 60 + secs
                found = true
                working = removingMatch(m, from: working)
            }
        }

        // Minutes
        let minMatches = allMatches(
            pattern: #"(?:(?:for)\s+)?(\d+(?:\.\d+)?)\s*(?:minutes?|mins?)\b"#,
            in: working
        )
        for m in minMatches.reversed() {
            if let valStr = captureGroup(1, in: m, text: working),
               let val = Double(valStr), val > 0 {
                totalSeconds += Int((val * 60.0).rounded())
                found = true
                working = removingMatch(m, from: working)
            }
        }

        // Seconds
        let secMatches = allMatches(
            pattern: #"(?:(?:for|and)\s+)?(\d+(?:\.\d+)?)\s*(?:seconds?|secs?)\b"#,
            in: working
        )
        for m in secMatches.reversed() {
            if let valStr = captureGroup(1, in: m, text: working),
               let val = Double(valStr), val > 0 {
                totalSeconds += Int(val.rounded())
                found = true
                working = removingMatch(m, from: working)
            }
        }

        return (found && totalSeconds > 0 ? totalSeconds : nil, working)
    }

    private static func extractWeight(
        from input: String
    ) -> (value: Double?, unit: WeightUnit?, remaining: String) {
        let pattern = #"(?:(?:at|@|with|for)\s+)?(?<![a-z0-9])(\d+(?:\.\d+)?)\s*(kg|kgs|kilos?|kilograms?|lbs?|pounds?)\b"#
        guard let m = firstMatch(pattern: pattern, in: input),
              let numStr = captureGroup(1, in: m, text: input),
              let unitStr = captureGroup(2, in: m, text: input),
              let value = Double(numStr), value > 0 else {
            return (nil, nil, input)
        }

        let lowerUnit = unitStr.lowercased()
        let unit: WeightUnit = (lowerUnit.hasPrefix("lb") || lowerUnit.hasPrefix("pound")) ? .lbs : .kg
        let remaining = removingMatch(m, from: input)
        return (value, unit, remaining)
    }

    // MARK: - Exercise Name Cleanup

    private static func cleanExerciseName(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "!", with: " ")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "@", with: " ")

        text = collapseWhitespace(text)

        // Strip common spoken preamble verbs
        let leadingPhrases = [
            #"^(?:i\s+just\s+did|just\s+did|i\s+did|i\s+just\s+finished|just\s+finished|i\s+finished|finished|completed|log|logged|add|added|record|track|put\s+down|did|doing|do)\b\s*"#,
            #"^(?:on\s+the|on\s+my|on|the|my|a|an|some|another|more|of|for|at|with|to|set|sets|rep|reps|and)\b\s*"#
        ]

        var previous = ""
        while previous != text {
            previous = text
            for pattern in leadingPhrases {
                text = replaceMatches(pattern: pattern, in: text, with: "")
                text = collapseWhitespace(text)
            }
        }

        // Strip stray trailing prepositions/fillers
        let trailingPattern = #"\s*\b(?:of|for|at|with|to|on|in|the|a|an|my|set|sets|rep|reps|and|again|more)\b$"#
        previous = ""
        while previous != text {
            previous = text
            text = replaceMatches(pattern: trailingPattern, in: text, with: "")
            text = collapseWhitespace(text)
        }

        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isContinuationPhrase(_ cleaned: String) -> Bool {
        let continuationPhrases: Set<String> = [
            "", "same", "same thing", "same exercise", "that", "it", "this",
            "this exercise", "last", "last one", "last exercise", "another",
            "another one", "one more", "more", "again"
        ]
        return continuationPhrases.contains(cleaned.lowercased())
    }

    // MARK: - Summary Formatting

    private static func buildLogSummary(items: [ParsedSetGroupIntent], defaultUnit: WeightUnit) -> String {
        items.map { item in
            var parts: [String] = [item.exerciseName]
            if item.tag != .normal {
                parts.append(item.tag.displayLabel)
            }
            if let reps = item.reps {
                if item.setCount > 1 {
                    parts.append("\(item.setCount) × \(reps)")
                } else {
                    parts.append("\(reps) reps")
                }
            } else if let duration = item.durationSeconds {
                let durText = DurationFormatter.formatCompact(seconds: duration)
                parts.append(item.setCount > 1 ? "\(item.setCount) × \(durText)" : durText)
            } else {
                parts.append("\(item.setCount) \(item.setCount == 1 ? "set" : "sets")")
            }
            if let weightValue = item.weightValue, weightValue > 0 {
                let unit = item.weightUnit ?? defaultUnit
                parts.append(formatWeightValue(weightValue, unit: unit))
            }
            return parts.joined(separator: " · ")
        }.joined(separator: ", ")
    }

    private static func formatWeightValue(_ value: Double, unit: WeightUnit) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded)) \(unit.rawValue)"
        }
        return String(format: "%.1f %@", rounded, unit.rawValue)
    }

    private static func unknownIntent(rawTranscript: String) -> WorkoutCommandIntent {
        WorkoutCommandIntent(
            action: .unknown,
            items: [],
            summary: "Didn't recognize a workout command",
            rawTranscript: rawTranscript,
            parserSource: .ruleBased
        )
    }

    // MARK: - Regex Helpers

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private static func allMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range)
    }

    private static func captureGroup(_ index: Int, in match: NSTextCheckingResult, text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func removingMatch(_ match: NSTextCheckingResult, from text: String) -> String {
        guard let range = Range(match.range, in: text) else { return text }
        var copy = text
        copy.replaceSubrange(range, with: " ")
        return copy
    }

    private static func replaceMatches(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
