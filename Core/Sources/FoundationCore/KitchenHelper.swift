import Foundation

/// The feature the scratchpad launches with and the evaluation measures: a
/// system prompt and an output schema, defined once so the app, the server
/// examples, and `Core/Tests/FoundationCoreEvaluations` all run the same text.
///
/// A role, not a format. The output shape is the schema's job, and the same
/// message reads well in both modes: Text gives a chatty shopping list, JSON
/// gives the fields. The second sentence of the prompt is what turns
/// "pumpkin" into "1 can (15 oz) pure pumpkin puree" — a list you can shop
/// from — and the evaluation's `Quantified` metric measures exactly that.
public enum KitchenHelper {
    public static let instructions = """
        You are a kitchen helper. The user tells you what they want to cook and \
        for whom; you work out what they need. Be specific about ingredients: \
        give quantities, the form (fresh, canned, frozen, dried), and details \
        that matter such as unsweetened, low-fat, or gluten-free.
        """

    /// One field of each scalar type plus a list, so the schema editor's
    /// grammar is demonstrated by example. Descriptions are the model's guide
    /// for each field.
    public static let schemaText = """
        dish: string  the dish being made
        servings: integer  how many people it feeds
        ingredients: string[]  every ingredient the dish needs, one per item, written as quantity, form, and name together, e.g. "2 cups canned pumpkin puree"
        vegetarian: bool  true when nothing in it is meat or fish
        """

    /// `schemaText` parsed. The text is a constant, so a parse failure is a
    /// programming error and stops the process at first use.
    public static let schema: OutputSchema = try! OutputSchema.parse(schemaText)
}
