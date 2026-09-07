import Foundation
import Testing
import Evaluations

/// Runs `KitchenHelperEvaluation` and gates on the quantitative metrics.
///
/// The thresholds are the measured baseline of the shipped prompt on the
/// on-device model, less one sample of slack for the model's run-to-run
/// variation. They are tripwires, not targets: a prompt or schema change
/// that drops below one has made the feature worse on a case this dataset
/// covers. The judge's scores are printed for reading and
/// deliberately not asserted — see the README.
@Suite("Kitchen helper")
struct KitchenHelperEvaluationTests {
    static let evaluation = KitchenHelperEvaluation()

    @Test(
        "Prompt and schema",
        .evaluates(
            evaluation,
            info: ["model": evaluation.modelName, "judge": evaluation.judgeName],
            recordTranscripts: true
        )
    )
    func promptAndSchema() throws {
        let result = EvaluationContext.current.result
        let e = Self.evaluation
        print(result.groupedSummary)

        // `KITCHEN_RESULTS=<dir>` writes the full per-sample result as JSON,
        // prompt, answer, every metric and rationale, so two runs can be
        // diffed outside Xcode.
        if let dir = ProcessInfo.processInfo.environment["KITCHEN_RESULTS"] {
            let url = try result.saveJSON(
                to: URL(fileURLWithPath: dir), includeReportMetadata: true, includeTranscripts: true
            )
            print("Results written to \(url.path)")
        }

        // Twelve samples, so one sample moves a pass rate by 0.083. Each
        // threshold sits one sample below the lowest value seen in four runs
        // of the shipped prompt. ListLength is the metric the model moves
        // most between runs (0.75–1.0), hence the wide margin.
        #expect(result.aggregateValue(.mean(of: e.servings)) >= 0.8)
        #expect(result.aggregateValue(.mean(of: e.vegetarianFlag)) >= 0.9)
        #expect(result.aggregateValue(.mean(of: e.flagMatchesList)) >= 0.9)
        #expect(result.aggregateValue(.mean(of: e.namedIngredients)) >= 0.75)
        #expect(result.aggregateValue(.mean(of: e.listLength)) >= 0.65)
        #expect(result.aggregateValue(.mean(of: e.quantified)) >= 0.85)
    }
}
