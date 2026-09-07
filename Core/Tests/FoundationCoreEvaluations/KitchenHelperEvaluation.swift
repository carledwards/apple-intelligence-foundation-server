import Foundation
import FoundationModels
import Evaluations
import FoundationCore

/// One kitchen-helper answer, in the shape `KitchenHelper.schema` guides.
///
/// The same type carries a sample's expectation. There, nil means "not
/// checked", and `ingredients` lists words that must appear somewhere in the
/// answer's list — not the whole list, which is the model's to choose.
struct Dish: Codable, Sendable {
    var dish: String?
    var servings: Int?
    var ingredients: [String]?
    var vegetarian: Bool?
}

/// Measures `KitchenHelper` — its prompt and its schema — over a fixed set of
/// asks.
///
/// Five quantitative metrics check what code can check; one model judge
/// scores what only words describe. The judge's numbers are reported but not
/// gated on: see `KitchenHelperEvaluationTests`.
struct KitchenHelperEvaluation: Evaluation {
    typealias Sample = ModelSample<Dish>
    typealias Subject = ModelSubject<Dish>

    /// The model under test. `KITCHEN_MODEL=private_cloud` switches it to
    /// Private Cloud Compute, which needs the entitlement the app carries.
    let model: any LanguageModel
    let modelName: String
    /// The model scoring the qualitative dimensions. `KITCHEN_JUDGE=private_cloud`
    /// switches it; the default is the on-device model, judging itself.
    let judge: any LanguageModel
    let judgeName: String

    init() {
        let env = ProcessInfo.processInfo.environment
        (model, modelName) = Self.pick(env["KITCHEN_MODEL"])
        (judge, judgeName) = Self.pick(env["KITCHEN_JUDGE"])
    }

    private static func pick(_ choice: String?) -> (any LanguageModel, String) {
        choice == ModelChoice.privateCloud.rawValue
            ? (PrivateCloudComputeLanguageModel(), ModelChoice.privateCloud.rawValue)
            : (SystemLanguageModel.default, ModelChoice.onDevice.rawValue)
    }

    // MARK: Metrics

    /// `servings` equals the number asked for, including when the ask gives
    /// it in words ("for two", "my wife and me").
    let servings = Metric("Servings")
    /// `vegetarian` equals the expected flag.
    let vegetarianFlag = Metric("VegetarianFlag")
    /// `vegetarian` agrees with the ingredient list. Both come from the same
    /// answer, so this needs no expectation: a list with chicken in it and
    /// `vegetarian: true` is wrong whatever was asked.
    let flagMatchesList = Metric("FlagMatchesList")
    /// Every word the ask implies appears in some ingredient.
    let namedIngredients = Metric("NamedIngredients")
    /// Between 3 and 20 ingredients. Fewer is not worked out; more is not a
    /// list anyone shops from.
    let listLength = Metric("ListLength")
    /// The fraction of ingredients that carry a quantity — the thing the
    /// second sentence of the prompt asks for.
    let quantified = Metric("Quantified")

    let shoppable = ScoreDimension(
        "Shoppable",
        description: """
            Whether someone could buy everything on this list without guessing: \
            each item names a product, an amount, and the form that matters \
            (fresh, canned, unsweetened, gluten-free).
            """,
        scale: .numeric([
            4: "Every item is specific enough to buy",
            3: "One or two items need a guess",
            2: "Several items are vague",
            1: "Most items are just names",
        ])
    )
    let fitsTheAsk = ScoreDimension(
        "FitsTheAsk",
        description: """
            Whether the dish and its list fit what was asked: the occasion, the \
            people it is for, and any constraint such as easy, vegan, or gluten-free.
            """,
        scale: .numeric([
            4: "Fits the ask completely",
            3: "Fits, with one detail ignored",
            2: "Misses something the ask made important",
            1: "Does not fit the ask",
        ])
    )

    // MARK: Dataset

    static let generationSchema = try! KitchenHelper.schema.generationSchema()

    /// Twelve asks written by hand, varied in occasion, size, diet, and how
    /// the serving count is phrased.
    static let samples: [Sample] = [
        ask("Thanksgiving dessert for 10, easy to make", servings: 10, vegetarian: true),
        ask("Guacamole for 4", servings: 4, vegetarian: true, mentions: ["avocado"]),
        ask("Pancakes for two", servings: 2, vegetarian: true, mentions: ["flour"]),
        ask("Beef chili for 6", servings: 6, vegetarian: false, mentions: ["beef"]),
        ask("A vegan lunch for my daughter and her three friends", servings: 4, vegetarian: true),
        ask("Grilled salmon dinner for my wife and me", servings: 2, vegetarian: false, mentions: ["salmon"]),
        ask("Birthday cake for 12 kids, one of them is gluten-free", servings: 12, vegetarian: true, mentions: ["gluten"]),
        ask("Something with chicken and rice for 3", servings: 3, vegetarian: false, mentions: ["chicken", "rice"]),
        ask("Vegetarian tacos for 5", servings: 5, vegetarian: true),
        ask("Spaghetti carbonara for 4", servings: 4, vegetarian: false, mentions: ["egg"]),
        ask("Tomato soup for one", servings: 1, vegetarian: true, mentions: ["tomato"]),
        ask("Ribs for 8 on the grill", servings: 8, vegetarian: false),
    ]

    private static func ask(
        _ prompt: String, servings: Int? = nil, vegetarian: Bool? = nil, mentions: [String] = []
    ) -> Sample {
        ModelSample(
            prompt: prompt,
            expected: Dish(
                servings: servings,
                ingredients: mentions.isEmpty ? nil : mentions,
                vegetarian: vegetarian
            ),
            instructions: KitchenHelper.instructions,
            generationSchema: generationSchema
        )
    }

    var dataset: ArrayLoader<Sample> { ArrayLoader(samples: Self.samples) }

    // MARK: Subject

    /// One fresh session per sample, calling the framework the way the app
    /// does: instructions at creation, the schema on the request. The session
    /// transcript is kept so the report shows the exact exchange.
    func subject(from sample: Sample) async throws -> Subject {
        let session = LanguageModelSession(model: model, instructions: sample.instructions)
        let response = try await session.respond(to: sample.prompt, schema: Self.generationSchema)
        let dish = try JSONDecoder().decode(Dish.self, from: Data(response.content.jsonString.utf8))
        return ModelSubject(value: dish, transcript: session.transcript.structuredTranscript)
    }

    // MARK: Evaluators

    var evaluators: Evaluators {
        Evaluator { sample, subject in
            guard let want = sample.expected?.servings else { return servings.ignore() }
            let got = subject.value.servings ?? 0
            return got == want
                ? servings.passing(rationale: "\(got)")
                : servings.failing(rationale: "got \(got), asked for \(want)")
        }

        Evaluator { sample, subject in
            guard let want = sample.expected?.vegetarian else { return vegetarianFlag.ignore() }
            let got = subject.value.vegetarian ?? false
            return got == want
                ? vegetarianFlag.passing()
                : vegetarianFlag.failing(rationale: "flag \(got), expected \(want)")
        }

        Evaluator { _, subject in
            let list = subject.value.ingredients ?? []
            let meat = list.filter(Self.namesMeat)
            let flag = subject.value.vegetarian ?? false
            if flag == meat.isEmpty { return flagMatchesList.passing() }
            return flagMatchesList.failing(
                rationale: flag ? "vegetarian: true with \(meat.joined(separator: ", "))"
                                : "vegetarian: false with nothing from an animal listed"
            )
        }

        Evaluator { sample, subject in
            guard let words = sample.expected?.ingredients else { return namedIngredients.ignore() }
            let list = (subject.value.ingredients ?? []).map { $0.lowercased() }
            let missing = words.filter { word in !list.contains { $0.contains(word.lowercased()) } }
            return missing.isEmpty
                ? namedIngredients.passing()
                : namedIngredients.failing(rationale: "no ingredient mentions \(missing.joined(separator: ", "))")
        }

        Evaluator { _, subject in
            let count = subject.value.ingredients?.count ?? 0
            return (3...20).contains(count)
                ? listLength.passing(rationale: "\(count) ingredients")
                : listLength.failing(rationale: "\(count) ingredients")
        }

        Evaluator { _, subject in
            let list = subject.value.ingredients ?? []
            guard !list.isEmpty else { return quantified.scoring(0, rationale: "no ingredients") }
            let bare = list.filter { !Self.hasQuantity($0) }
            let share = Double(list.count - bare.count) / Double(list.count)
            return quantified.scoring(
                share,
                rationale: bare.isEmpty ? "every item has a quantity" : "no quantity on: \(bare.joined(separator: "; "))"
            )
        }

        ModelJudgeEvaluator(
            judge: judge,
            dimensions: [shoppable, fitsTheAsk],
            prompt: ModelJudgePrompt(
                instructions: """
                    You are evaluating a kitchen-helper feature in a cooking app. The user \
                    typed a short request; the app answered with a dish, a serving count, \
                    and an ingredient list meant to be taken to a store.
                    """,
                evaluationTarget: { dish in
                    """
                    Dish: \(dish.dish ?? "")
                    Servings: \(dish.servings ?? 0)
                    Vegetarian: \(dish.vegetarian ?? false)
                    Ingredients:
                    \((dish.ingredients ?? []).map { "- \($0)" }.joined(separator: "\n"))
                    """
                },
                reference: { sample, _ in ["The user's request": sample.promptDescription] }
            )
        )
    }

    // MARK: Aggregation

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        for metric in [servings, vegetarianFlag, flagMatchesList, namedIngredients, listLength] {
            aggregator.computeMean(of: metric)
        }
        aggregator.computeMean(of: quantified)
        aggregator.computeMinimum(of: quantified)
        aggregator.computeMean(of: shoppable.metric)
        aggregator.computeMean(of: fitsTheAsk.metric)
    }

    // MARK: Heuristics

    /// A digit, a fraction glyph, or a measure word anywhere in the item.
    static func hasQuantity(_ item: String) -> Bool {
        if item.contains(where: \.isNumber) { return true }
        return !words(in: item).isDisjoint(with: quantityWords)
    }

    static func namesMeat(_ item: String) -> Bool {
        !words(in: item).isDisjoint(with: meatWords)
    }

    private static func words(in item: String) -> Set<String> {
        Set(item.lowercased().split { !$0.isLetter }.map(String.init))
    }

    private static let quantityWords: Set<String> = [
        "a", "an", "one", "two", "three", "four", "five", "six", "half", "dozen",
        "pinch", "dash", "splash", "drizzle", "handful", "taste",
        "clove", "cloves", "cup", "cups", "tablespoon", "tablespoons", "tbsp",
        "teaspoon", "teaspoons", "tsp", "oz", "ounce", "ounces", "lb", "lbs",
        "pound", "pounds", "g", "gram", "grams", "kg", "ml", "l", "liter", "litre",
        "can", "cans", "jar", "jars", "bunch", "slice", "slices", "stick", "sticks",
        "package", "pkg", "bag", "sprig", "sprigs", "head", "stalk", "stalks",
    ]

    private static let meatWords: Set<String> = [
        "beef", "steak", "veal", "chicken", "turkey", "duck", "pork", "bacon",
        "pancetta", "guanciale", "prosciutto", "ham", "sausage", "chorizo", "ribs",
        "lamb", "salmon", "tuna", "cod", "fish", "anchovy", "anchovies", "shrimp",
        "prawn", "prawns", "crab", "lobster", "clams", "mussels", "oysters", "gelatin",
    ]
}
