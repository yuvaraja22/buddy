import Foundation

public struct ExerciseDefinition: Equatable, Sendable {
    public let canonicalName: String
    public let muscleGroup: MuscleGroup
    public let aliases: [String]

    public init(canonicalName: String, muscleGroup: MuscleGroup, aliases: [String] = []) {
        self.canonicalName = canonicalName
        self.muscleGroup = muscleGroup
        self.aliases = aliases
    }
}

public enum ExerciseCatalog {
    /// Curated catalog of common gym exercises. The first 30 entries are the highest-frequency
    /// movements so `promptHint(limit: 30)` supplies the best canonical names to the local LLM.
    public static let all: [ExerciseDefinition] = [
        // MARK: - Top 30 Core Movements
        ExerciseDefinition(
            canonicalName: "Leg Extension",
            muscleGroup: .quads,
            aliases: [
                "leg extensions", "quad extension", "quad extensions",
                "seated leg extension", "machine leg extension", "knee extension"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Leg Press",
            muscleGroup: .quads,
            aliases: [
                "leg presses", "45 degree leg press", "sled leg press",
                "machine leg press", "angled leg press"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Squat",
            muscleGroup: .quads,
            aliases: [
                "squats", "back squat", "back squats", "barbell squat",
                "barbell squats", "barbell back squat", "bb squat"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Bulgarian Split Squat",
            muscleGroup: .quads,
            aliases: [
                "bulgarian split squats", "split squat", "split squats",
                "bss", "rear foot elevated split squat", "rfess"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Leg Curl",
            muscleGroup: .hamstrings,
            aliases: [
                "leg curls", "hamstring curl", "hamstring curls",
                "machine leg curl", "standing leg curl"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Romanian Deadlift",
            muscleGroup: .hamstrings,
            aliases: [
                "romanian deadlifts", "rdl", "rdls", "db rdl", "dumbbell rdl",
                "barbell rdl", "dumbbell romanian deadlift", "barbell romanian deadlift"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Hip Thrust",
            muscleGroup: .glutes,
            aliases: [
                "hip thrusts", "barbell hip thrust", "glute thrust",
                "machine hip thrust", "smith hip thrust"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Standing Calf Raise",
            muscleGroup: .calves,
            aliases: [
                "calf raise", "calf raises", "standing calf raises",
                "machine calf raise", "smith calf raise"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Bench Press",
            muscleGroup: .chest,
            aliases: [
                "barbell bench press", "flat bench", "flat bench press",
                "bb bench", "bb bench press", "bench", "chest bench"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Incline Dumbbell Press",
            muscleGroup: .chest,
            aliases: [
                "incline db press", "incline db bench", "incline dumbbell bench",
                "incline dumbbell bench press", "incline dumbbell chest press"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Dumbbell Bench Press",
            muscleGroup: .chest,
            aliases: [
                "db bench", "db bench press", "dumbbell bench",
                "flat db press", "flat dumbbell press", "flat dumbbell bench"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Cable Fly",
            muscleGroup: .chest,
            aliases: [
                "cable flys", "cable flies", "cable chest fly", "cable crossover",
                "cable crossovers", "high to low cable fly", "low to high cable fly"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Push-Up",
            muscleGroup: .chest,
            aliases: [
                "pushup", "pushups", "push up", "push ups", "push-ups",
                "diamond pushup", "incline pushup"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Deadlift",
            muscleGroup: .back,
            aliases: [
                "deadlifts", "conventional deadlift", "barbell deadlift", "dl", "bb deadlift"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Lat Pulldown",
            muscleGroup: .back,
            aliases: [
                "lat pull down", "lat pulldowns", "lat pull downs",
                "wide grip lat pulldown", "cable lat pulldown", "pulldown", "pull down"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Seated Cable Row",
            muscleGroup: .back,
            aliases: [
                "cable row", "cable rows", "seated row", "seated rows",
                "low cable row", "low row", "v-bar row", "close grip cable row"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Pull-Up",
            muscleGroup: .back,
            aliases: [
                "pullup", "pullups", "pull up", "pull ups", "pull-ups",
                "weighted pull-up", "assisted pull-up", "wide grip pull-up"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Barbell Row",
            muscleGroup: .back,
            aliases: [
                "barbell rows", "bent over row", "bent over rows",
                "bent over barbell row", "bb row", "pendlay row"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Dumbbell Row",
            muscleGroup: .back,
            aliases: [
                "dumbbell rows", "db row", "db rows", "one arm dumbbell row",
                "single arm dumbbell row", "single arm row", "one arm row", "kroc row"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Overhead Press",
            muscleGroup: .shoulders,
            aliases: [
                "ohp", "military press", "barbell overhead press",
                "standing overhead press", "strict press", "barbell shoulder press", "shoulder press"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Dumbbell Shoulder Press",
            muscleGroup: .shoulders,
            aliases: [
                "db shoulder press", "seated dumbbell shoulder press",
                "seated db shoulder press", "db overhead press", "dumbbell ohp"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Lateral Raise",
            muscleGroup: .shoulders,
            aliases: [
                "lateral raises", "side raise", "side raises", "side lateral raise",
                "dumbbell lateral raise", "db lateral raise", "lat raise", "lat raises"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Face Pull",
            muscleGroup: .shoulders,
            aliases: ["face pulls", "cable face pull", "rope face pull"]
        ),
        ExerciseDefinition(
            canonicalName: "Bicep Curl",
            muscleGroup: .biceps,
            aliases: [
                "bicep curls", "biceps curl", "biceps curls", "dumbbell curl",
                "dumbbell curls", "db curl", "db curls", "arm curl", "arm curls", "curls"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Hammer Curl",
            muscleGroup: .biceps,
            aliases: [
                "hammer curls", "dumbbell hammer curl", "db hammer curl", "rope hammer curl"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Tricep Pushdown",
            muscleGroup: .triceps,
            aliases: [
                "tricep pushdowns", "triceps pushdown", "triceps pushdowns",
                "cable pushdown", "cable tricep pushdown", "tricep pressdown",
                "pushdown", "pushdowns"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Overhead Tricep Extension",
            muscleGroup: .triceps,
            aliases: [
                "overhead tricep extensions", "tricep extension", "tricep extensions",
                "cable overhead tricep extension", "dumbbell tricep extension",
                "overhead cable extension", "french press"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Plank",
            muscleGroup: .core,
            aliases: ["planks", "forearm plank", "front plank", "high plank", "elbow plank"]
        ),
        ExerciseDefinition(
            canonicalName: "Hanging Leg Raise",
            muscleGroup: .core,
            aliases: [
                "hanging leg raises", "leg raise", "leg raises",
                "hanging knee raise", "hanging knee raises", "captains chair leg raise"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Treadmill",
            muscleGroup: .cardio,
            aliases: [
                "treadmill run", "treadmill jog", "treadmill walk",
                "run on treadmill", "walk on treadmill"
            ]
        ),

        // MARK: - Additional Quads
        ExerciseDefinition(
            canonicalName: "Front Squat",
            muscleGroup: .quads,
            aliases: ["front squats", "barbell front squat"]
        ),
        ExerciseDefinition(
            canonicalName: "Goblet Squat",
            muscleGroup: .quads,
            aliases: ["goblet squats", "dumbbell goblet squat", "kettlebell goblet squat"]
        ),
        ExerciseDefinition(
            canonicalName: "Hack Squat",
            muscleGroup: .quads,
            aliases: ["hack squats", "machine hack squat", "pendulum squat"]
        ),
        ExerciseDefinition(
            canonicalName: "Smith Machine Squat",
            muscleGroup: .quads,
            aliases: ["smith squat", "smith squats"]
        ),
        ExerciseDefinition(
            canonicalName: "Walking Lunge",
            muscleGroup: .quads,
            aliases: [
                "walking lunges", "lunge", "lunges", "dumbbell lunge",
                "dumbbell lunges", "db lunge", "db lunges", "forward lunge"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Reverse Lunge",
            muscleGroup: .quads,
            aliases: ["reverse lunges", "dumbbell reverse lunge", "barbell reverse lunge"]
        ),
        ExerciseDefinition(
            canonicalName: "Step-Up",
            muscleGroup: .quads,
            aliases: ["step up", "step ups", "step-ups", "stepup", "dumbbell step up", "box step up"]
        ),
        ExerciseDefinition(
            canonicalName: "Sissy Squat",
            muscleGroup: .quads,
            aliases: ["sissy squats"]
        ),

        // MARK: - Additional Hamstrings
        ExerciseDefinition(
            canonicalName: "Lying Leg Curl",
            muscleGroup: .hamstrings,
            aliases: ["lying leg curls", "prone leg curl", "lying hamstring curl"]
        ),
        ExerciseDefinition(
            canonicalName: "Seated Leg Curl",
            muscleGroup: .hamstrings,
            aliases: ["seated leg curls", "seated hamstring curl"]
        ),
        ExerciseDefinition(
            canonicalName: "Stiff-Leg Deadlift",
            muscleGroup: .hamstrings,
            aliases: ["stiff leg deadlift", "stiff legged deadlift", "sldl", "straight leg deadlift"]
        ),
        ExerciseDefinition(
            canonicalName: "Good Morning",
            muscleGroup: .hamstrings,
            aliases: ["good mornings", "barbell good morning"]
        ),
        ExerciseDefinition(
            canonicalName: "Nordic Hamstring Curl",
            muscleGroup: .hamstrings,
            aliases: ["nordic curl", "nordic curls", "glute ham raise", "ghr"]
        ),

        // MARK: - Additional Glutes
        ExerciseDefinition(
            canonicalName: "Glute Bridge",
            muscleGroup: .glutes,
            aliases: ["glute bridges", "barbell glute bridge", "single leg glute bridge"]
        ),
        ExerciseDefinition(
            canonicalName: "Cable Kickback",
            muscleGroup: .glutes,
            aliases: ["glute kickback", "glute kickbacks", "cable glute kickback", "donkey kick"]
        ),
        ExerciseDefinition(
            canonicalName: "Hip Abduction",
            muscleGroup: .glutes,
            aliases: ["hip abductions", "abductor machine", "hip abductor", "seated hip abduction"]
        ),
        ExerciseDefinition(
            canonicalName: "Hip Adduction",
            muscleGroup: .glutes,
            aliases: ["hip adductions", "adductor machine", "hip adductor", "seated hip adduction"]
        ),
        ExerciseDefinition(
            canonicalName: "Sumo Deadlift",
            muscleGroup: .glutes,
            aliases: ["sumo deadlifts", "sumo dl"]
        ),
        ExerciseDefinition(
            canonicalName: "Kettlebell Swing",
            muscleGroup: .glutes,
            aliases: ["kettlebell swings", "kb swing", "kb swings"]
        ),

        // MARK: - Additional Calves
        ExerciseDefinition(
            canonicalName: "Seated Calf Raise",
            muscleGroup: .calves,
            aliases: ["seated calf raises"]
        ),
        ExerciseDefinition(
            canonicalName: "Donkey Calf Raise",
            muscleGroup: .calves,
            aliases: ["donkey calf raises"]
        ),
        ExerciseDefinition(
            canonicalName: "Leg Press Calf Raise",
            muscleGroup: .calves,
            aliases: ["calf press", "leg press calves", "calf press on leg press"]
        ),

        // MARK: - Additional Chest
        ExerciseDefinition(
            canonicalName: "Incline Barbell Press",
            muscleGroup: .chest,
            aliases: [
                "incline bench", "incline bench press", "incline barbell bench",
                "incline barbell bench press", "incline bb press", "incline press"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Decline Bench Press",
            muscleGroup: .chest,
            aliases: ["decline bench", "decline barbell press", "decline dumbbell press", "decline press"]
        ),
        ExerciseDefinition(
            canonicalName: "Chest Press Machine",
            muscleGroup: .chest,
            aliases: ["chest press", "machine chest press", "seated chest press", "converging chest press"]
        ),
        ExerciseDefinition(
            canonicalName: "Dumbbell Fly",
            muscleGroup: .chest,
            aliases: ["dumbbell flys", "dumbbell flies", "db fly", "db flies", "incline dumbbell fly", "chest fly"]
        ),
        ExerciseDefinition(
            canonicalName: "Pec Deck",
            muscleGroup: .chest,
            aliases: ["pec deck fly", "pec fly", "machine fly", "butterfly machine"]
        ),
        ExerciseDefinition(
            canonicalName: "Chest Dip",
            muscleGroup: .chest,
            aliases: ["chest dips", "dips", "dip", "weighted dips", "parallel bar dip"]
        ),

        // MARK: - Additional Back
        ExerciseDefinition(
            canonicalName: "Chin-Up",
            muscleGroup: .back,
            aliases: ["chinup", "chinups", "chin up", "chin ups", "chin-ups", "weighted chin-up"]
        ),
        ExerciseDefinition(
            canonicalName: "T-Bar Row",
            muscleGroup: .back,
            aliases: ["t bar row", "tbar row", "t-bar rows", "landmine row"]
        ),
        ExerciseDefinition(
            canonicalName: "Chest-Supported Row",
            muscleGroup: .back,
            aliases: [
                "chest supported row", "chest supported rows",
                "machine row", "machine rows", "incline dumbbell row", "seal row"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Straight-Arm Pulldown",
            muscleGroup: .back,
            aliases: [
                "straight arm pulldown", "straight arm pull down",
                "lat pullover", "cable pullover", "rope pullover"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Rack Pull",
            muscleGroup: .back,
            aliases: ["rack pulls", "block pull"]
        ),
        ExerciseDefinition(
            canonicalName: "Back Extension",
            muscleGroup: .back,
            aliases: ["back extensions", "hyperextension", "hyperextensions", "45 degree back extension"]
        ),
        ExerciseDefinition(
            canonicalName: "Barbell Shrug",
            muscleGroup: .back,
            aliases: ["shrug", "shrugs", "barbell shrugs", "dumbbell shrug", "dumbbell shrugs", "db shrug", "trap shrug"]
        ),

        // MARK: - Additional Shoulders
        ExerciseDefinition(
            canonicalName: "Arnold Press",
            muscleGroup: .shoulders,
            aliases: ["arnold presses", "dumbbell arnold press"]
        ),
        ExerciseDefinition(
            canonicalName: "Machine Shoulder Press",
            muscleGroup: .shoulders,
            aliases: ["shoulder press machine", "smith shoulder press", "smith overhead press"]
        ),
        ExerciseDefinition(
            canonicalName: "Cable Lateral Raise",
            muscleGroup: .shoulders,
            aliases: ["cable lateral raises", "cable side raise", "single arm cable lateral raise"]
        ),
        ExerciseDefinition(
            canonicalName: "Front Raise",
            muscleGroup: .shoulders,
            aliases: ["front raises", "dumbbell front raise", "plate front raise", "cable front raise"]
        ),
        ExerciseDefinition(
            canonicalName: "Rear Delt Fly",
            muscleGroup: .shoulders,
            aliases: [
                "rear delt flies", "rear delt flys", "reverse pec deck",
                "reverse fly", "rear delt machine", "bent over lateral raise"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Upright Row",
            muscleGroup: .shoulders,
            aliases: ["upright rows", "barbell upright row", "cable upright row"]
        ),

        // MARK: - Additional Biceps
        ExerciseDefinition(
            canonicalName: "Barbell Curl",
            muscleGroup: .biceps,
            aliases: ["barbell curls", "bb curl", "bb curls", "straight bar curl"]
        ),
        ExerciseDefinition(
            canonicalName: "EZ-Bar Curl",
            muscleGroup: .biceps,
            aliases: ["ez bar curl", "ez bar curls", "ez curl", "ez curls"]
        ),
        ExerciseDefinition(
            canonicalName: "Preacher Curl",
            muscleGroup: .biceps,
            aliases: ["preacher curls", "machine preacher curl", "ez bar preacher curl"]
        ),
        ExerciseDefinition(
            canonicalName: "Incline Dumbbell Curl",
            muscleGroup: .biceps,
            aliases: ["incline curl", "incline curls", "incline db curl", "incline bicep curl"]
        ),
        ExerciseDefinition(
            canonicalName: "Cable Curl",
            muscleGroup: .biceps,
            aliases: ["cable curls", "cable bicep curl", "bayesian curl"]
        ),
        ExerciseDefinition(
            canonicalName: "Concentration Curl",
            muscleGroup: .biceps,
            aliases: ["concentration curls", "spider curl", "spider curls"]
        ),

        // MARK: - Additional Triceps
        ExerciseDefinition(
            canonicalName: "Rope Pushdown",
            muscleGroup: .triceps,
            aliases: ["rope pushdowns", "tricep rope pushdown", "rope tricep pushdown", "cable rope pushdown"]
        ),
        ExerciseDefinition(
            canonicalName: "Skull Crusher",
            muscleGroup: .triceps,
            aliases: [
                "skull crushers", "skullcrusher", "skullcrushers",
                "lying tricep extension", "ez bar skull crusher"
            ]
        ),
        ExerciseDefinition(
            canonicalName: "Close-Grip Bench Press",
            muscleGroup: .triceps,
            aliases: ["close grip bench", "close grip bench press", "cgbp"]
        ),
        ExerciseDefinition(
            canonicalName: "Tricep Dip",
            muscleGroup: .triceps,
            aliases: ["tricep dips", "triceps dips", "bench dip", "bench dips", "assisted tricep dip"]
        ),
        ExerciseDefinition(
            canonicalName: "Tricep Kickback",
            muscleGroup: .triceps,
            aliases: ["tricep kickbacks", "triceps kickback", "dumbbell kickback", "cable tricep kickback"]
        ),

        // MARK: - Additional Core
        ExerciseDefinition(
            canonicalName: "Side Plank",
            muscleGroup: .core,
            aliases: ["side planks"]
        ),
        ExerciseDefinition(
            canonicalName: "Cable Crunch",
            muscleGroup: .core,
            aliases: ["cable crunches", "kneeling cable crunch", "rope crunch"]
        ),
        ExerciseDefinition(
            canonicalName: "Crunch",
            muscleGroup: .core,
            aliases: ["crunches", "ab crunch", "ab crunches", "bicycle crunch", "machine crunch"]
        ),
        ExerciseDefinition(
            canonicalName: "Sit-Up",
            muscleGroup: .core,
            aliases: ["situp", "situps", "sit up", "sit ups", "sit-ups", "decline sit up", "decline sit-up"]
        ),
        ExerciseDefinition(
            canonicalName: "Russian Twist",
            muscleGroup: .core,
            aliases: ["russian twists", "weighted russian twist"]
        ),
        ExerciseDefinition(
            canonicalName: "Ab Wheel Rollout",
            muscleGroup: .core,
            aliases: ["ab wheel", "ab rollout", "ab rollouts", "wheel rollout"]
        ),
        ExerciseDefinition(
            canonicalName: "Dead Bug",
            muscleGroup: .core,
            aliases: ["dead bugs"]
        ),
        ExerciseDefinition(
            canonicalName: "Pallof Press",
            muscleGroup: .core,
            aliases: ["cable pallof press", "anti rotation press"]
        ),
        ExerciseDefinition(
            canonicalName: "Mountain Climber",
            muscleGroup: .core,
            aliases: ["mountain climbers"]
        ),

        // MARK: - Additional Cardio
        ExerciseDefinition(
            canonicalName: "Incline Walk",
            muscleGroup: .cardio,
            aliases: ["incline walking", "incline treadmill", "incline treadmill walk", "12 3 30"]
        ),
        ExerciseDefinition(
            canonicalName: "Running",
            muscleGroup: .cardio,
            aliases: ["run", "jog", "jogging", "outdoor run", "sprint", "sprints"]
        ),
        ExerciseDefinition(
            canonicalName: "Stationary Bike",
            muscleGroup: .cardio,
            aliases: ["bike", "cycling", "spin bike", "exercise bike", "assault bike", "air bike", "indoor cycling"]
        ),
        ExerciseDefinition(
            canonicalName: "Rowing Machine",
            muscleGroup: .cardio,
            aliases: ["rower", "erg", "concept2", "rowing", "cardio row"]
        ),
        ExerciseDefinition(
            canonicalName: "Elliptical",
            muscleGroup: .cardio,
            aliases: ["cross trainer", "elliptical trainer"]
        ),
        ExerciseDefinition(
            canonicalName: "Stairmaster",
            muscleGroup: .cardio,
            aliases: ["stair climber", "stairclimber", "stairs", "stepper"]
        ),
        ExerciseDefinition(
            canonicalName: "Jump Rope",
            muscleGroup: .cardio,
            aliases: ["skipping", "skipping rope", "double unders"]
        ),

        // MARK: - Full Body
        ExerciseDefinition(
            canonicalName: "Burpee",
            muscleGroup: .fullBody,
            aliases: ["burpees"]
        ),
        ExerciseDefinition(
            canonicalName: "Thruster",
            muscleGroup: .fullBody,
            aliases: ["thrusters", "barbell thruster", "dumbbell thruster"]
        ),
        ExerciseDefinition(
            canonicalName: "Clean and Press",
            muscleGroup: .fullBody,
            aliases: ["clean & press", "clean and jerk", "power clean", "hang clean"]
        ),
        ExerciseDefinition(
            canonicalName: "Farmer's Walk",
            muscleGroup: .fullBody,
            aliases: ["farmers walk", "farmer walk", "farmers carry", "farmer carry"]
        ),
        ExerciseDefinition(
            canonicalName: "Box Jump",
            muscleGroup: .fullBody,
            aliases: ["box jumps"]
        ),
        ExerciseDefinition(
            canonicalName: "Battle Ropes",
            muscleGroup: .fullBody,
            aliases: ["battle rope", "rope slams"]
        ),
        ExerciseDefinition(
            canonicalName: "Sled Push",
            muscleGroup: .fullBody,
            aliases: ["sled pushes", "prowler push", "sled pull", "sled drag"]
        )
    ]

    /// Precomputed normalized lookup entries for fast matching.
    private struct IndexedVariant: Sendable {
        let definition: ExerciseDefinition
        let normalized: String
        let singularized: String
        let tokens: Set<String>
    }

    private static let indexedVariants: [IndexedVariant] = {
        var result: [IndexedVariant] = []
        result.reserveCapacity(all.count * 5)
        for def in all {
            let names = [def.canonicalName] + def.aliases
            for name in names {
                let norm = normalize(name)
                let sing = singularizePhrase(norm)
                let toks = Set(sing.split(separator: " ").map(String.init))
                result.append(IndexedVariant(definition: def, normalized: norm, singularized: sing, tokens: toks))
            }
        }
        return result
    }()

    /// Resolves a spoken or typed exercise name to its canonical display name and muscle group.
    /// Falls back to a clean Title Cased name and keyword-inferred muscle group if unknown.
    public static func resolve(_ rawName: String) -> (displayName: String, canonicalName: String, muscleGroup: MuscleGroup) {
        let cleaned = cleanRawName(rawName)
        guard !cleaned.isEmpty else {
            return ("Exercise", "Exercise", .other)
        }

        let normQuery = normalize(cleaned)
        let singQuery = singularizePhrase(normQuery)
        let queryTokens = Set(singQuery.split(separator: " ").map(String.init))

        // 1. Exact normalized match
        if let exact = indexedVariants.first(where: { $0.normalized == normQuery }) {
            let def = exact.definition
            return (def.canonicalName, def.canonicalName, def.muscleGroup)
        }

        // 2. Exact singularized match
        if let singularExact = indexedVariants.first(where: { $0.singularized == singQuery }) {
            let def = singularExact.definition
            return (def.canonicalName, def.canonicalName, def.muscleGroup)
        }

        // 3. Token / substring similarity matching
        if !queryTokens.isEmpty {
            var bestDefinition: ExerciseDefinition?
            var bestScore: Double = 0

            for variant in indexedVariants where !variant.tokens.isEmpty {
                let intersection = queryTokens.intersection(variant.tokens)
                guard !intersection.isEmpty else { continue }

                let unionCount = queryTokens.union(variant.tokens).count
                var score = Double(intersection.count) / Double(unionCount)

                // Bonus for clean multi-word phrase containment
                let minTokens = min(queryTokens.count, variant.tokens.count)
                if minTokens >= 2 && (singQuery.contains(variant.singularized) || variant.singularized.contains(singQuery)) {
                    score += 0.12
                } else if minTokens == 1 && queryTokens.count == 1 && variant.tokens.count == 2 {
                    // Single-token query matching a prefix/substring of a 2-token variant
                    if variant.singularized.hasPrefix(singQuery) && singQuery.count >= 5 {
                        score += 0.15
                    }
                }

                if score > bestScore {
                    bestScore = score
                    bestDefinition = variant.definition
                }
            }

            if let matched = bestDefinition, bestScore >= 0.65 {
                return (matched.canonicalName, matched.canonicalName, matched.muscleGroup)
            }
        }

        // 4. Unknown exercise fallback: clean Title Case + keyword muscle inference
        let formatted = titleCase(cleaned)
        let inferred = inferMuscleGroup(from: normQuery)
        return (formatted, formatted, inferred)
    }

    /// Comma-separated list of top canonical exercise names for local LLM prompt grounding.
    public static func promptHint(limit: Int = 30) -> String {
        let count = max(0, min(limit, all.count))
        return all.prefix(count).map(\.canonicalName).joined(separator: ", ")
    }

    /// Precomputed normalized catalog names and unambiguous aliases sorted longest-first,
    /// used by `RuleBasedWorkoutParser` to split unpunctuated run-on post-gym voice dumps
    /// (e.g. "bench press 60 kg 3 sets 10 reps incline dumbbell press 20 kg 3 sets 12 reps").
    public static let longestFirstKnownPhrases: [String] = {
        let ambiguousSingleTokens: Set<String> = [
            "press", "row", "rows", "curl", "curls", "fly", "flys", "flies",
            "raise", "raises", "extension", "extensions", "pull", "push",
            "walk", "run", "bike", "cycle", "jump", "hold", "twist", "crunch"
        ]
        var seen = Set<String>()
        var phrases: [String] = []

        for variant in indexedVariants {
            let norm = variant.normalized
            guard norm.count >= 3 else { continue }
            if !norm.contains(" ") && ambiguousSingleTokens.contains(norm) {
                continue
            }
            if seen.insert(norm).inserted {
                phrases.append(norm)
            }
        }

        return phrases.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }
    }()

    // MARK: - Normalization & Inference Helpers

    private static func cleanRawName(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        return parts.joined(separator: " ")
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "&", with: " and ")

        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(lowered.unicodeScalars.count)
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func singularizePhrase(_ normalized: String) -> String {
        normalized
            .split(separator: " ")
            .map { singularizeWord(String($0)) }
            .joined(separator: " ")
    }

    private static func singularizeWord(_ word: String) -> String {
        if word.count <= 3 { return word }
        if word == "abs" || word == "calves" || word == "press" || word == "cross" || word == "glutes" {
            if word == "calves" { return "calf" }
            if word == "glutes" { return "glute" }
            return word
        }
        if word.hasSuffix("ies") && word.count > 4 {
            return String(word.dropLast(3)) + "y"
        }
        if word.hasSuffix("sses") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("xes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s") && !word.hasSuffix("ss") && !word.hasSuffix("us") {
            return String(word.dropLast())
        }
        return word
    }

    private static func titleCase(_ text: String) -> String {
        let acronyms: Set<String> = ["rdl", "ohp", "ez", "db", "bb", "hiit", "trx", "bss", "sldl", "ghr", "cgbp", "kb"]
        let lowercaseConnectors: Set<String> = ["and", "of", "on", "to", "with", "in", "for", "the", "a"]

        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.enumerated().map { index, word in
            let lower = word.lowercased()
            if acronyms.contains(lower) {
                return lower.uppercased()
            }
            if index > 0 && lowercaseConnectors.contains(lower) {
                return lower
            }
            if word.contains("-") {
                return word
                    .split(separator: "-", omittingEmptySubsequences: false)
                    .map { part -> String in
                        let partStr = String(part)
                        let partLower = partStr.lowercased()
                        if acronyms.contains(partLower) { return partLower.uppercased() }
                        guard let first = partLower.first else { return "" }
                        return String(first).uppercased() + partLower.dropFirst()
                    }
                    .joined(separator: "-")
            }
            guard let first = lower.first else { return "" }
            return String(first).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func inferMuscleGroup(from normalized: String) -> MuscleGroup {
        let padded = " \(normalized) "

        func containsAny(_ keywords: [String]) -> Bool {
            keywords.contains { kw in
                if kw.contains(" ") {
                    return padded.contains(" \(kw) ") || normalized.contains(kw)
                }
                return padded.contains(" \(kw) ") || normalized.contains(kw)
            }
        }

        // Order matters to disambiguate overlapping terms (e.g., "leg curl" -> hamstrings, "tricep dip" -> triceps)
        if containsAny(["treadmill", "jog", "sprint", "cycling", "bike", "elliptical", "stair", "jump rope", "swim", "cardio", "hiit", "skierg", "rower", "rowing", "incline walk", "running"]) {
            return .cardio
        }
        if containsAny(["hamstring", "leg curl", "rdl", "romanian", "stiff leg", "nordic", "good morning", "glute ham"]) {
            return .hamstrings
        }
        if containsAny(["quad", "squat", "leg press", "leg extension", "lunge", "step up", "hack"]) {
            return .quads
        }
        if containsAny(["glute", "hip thrust", "hip abduct", "hip adduct", "bridge", "sumo", "kettlebell swing"]) {
            return .glutes
        }
        if containsAny(["calf", "calves"]) {
            return .calves
        }
        if containsAny(["tricep", "pushdown", "pressdown", "skull crusher", "skullcrusher", "close grip", "french press"]) {
            return .triceps
        }
        if containsAny(["bicep", "preacher", "hammer curl", "curl"]) {
            return .biceps
        }
        if containsAny(["chest", "bench", "pec", "push up", "pushup", "fly", "dip"]) {
            return .chest
        }
        if containsAny(["shoulder", "delt", "overhead press", "ohp", "military", "arnold", "lateral raise", "front raise", "upright row", "face pull"]) {
            return .shoulders
        }
        if containsAny(["back", "lat", "pull up", "pullup", "chin up", "chinup", "pulldown", "pull down", "row", "deadlift", "pullover", "hyperextension", "shrug"]) {
            return .back
        }
        if containsAny(["core", "abs", "ab ", "plank", "crunch", "sit up", "situp", "leg raise", "russian twist", "rollout", "dead bug", "mountain climber", "pallof", "oblique"]) {
            return .core
        }
        if containsAny(["burpee", "thruster", "clean", "snatch", "farmer", "sled", "battle rope", "box jump", "turkish"]) {
            return .fullBody
        }
        return .other
    }
}
