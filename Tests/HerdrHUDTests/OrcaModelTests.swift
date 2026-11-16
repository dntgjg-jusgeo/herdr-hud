import XCTest
@testable import HerdrHUD

final class OrcaModelTests: XCTestCase {
    let today=ISO8601DateFormatter().date(from:"2026-11-16T12:00:00Z")!
    var calendar: Calendar { var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(identifier:"America/Chicago")!;return value }
    func record(_ id:String,name:String?=nil,owner:String="Independent",types:[String]=["openai"],parameters:[String]?=["tools"],context:Any?=100000) -> Row {
        var row:Row=["id":id,"name":name ?? id,"owned_by":owner,"supported_endpoint_types":types,"created":1_600_000_000]
        if let parameters=parameters { row["supported_parameters"]=parameters };if let context=context { row["context_length"]=context };return row
    }
    func releases(_ values:[String:String]) -> [String:Row] { values.mapValues { ["releaseDate":$0,"sourceURL":"https://publisher.example/releases/exact-model"] } }
    func data(_ rows:[Row]) throws -> Data { try JSONSerialization.data(withJSONObject:["object":"list","data":rows]) }
    func models(_ envelope:Row) -> [Row] { envelope["models"] as! [Row] }
    func testVisionRequiresExplicitImageInputMetadata() throws {
        var visual=record("independent/visual");visual["architecture"]=["input_modalities":["text","image"]]
        let result=try OrcaModels.normalize(data([visual,record("independent/unknown")]),releases:releases(["independent/visual":"2026-10-01","independent/unknown":"2026-10-01"]),now:today,calendar:calendar)
        XCTAssertEqual(models(result).first{$0["id"] as? String == "independent/visual"}?["vision"] as? Bool,true)
        XCTAssertEqual(models(result).first{$0["id"] as? String == "independent/unknown"}?["vision"] as? Bool,false)
    }
    func testLocalCalendarWindowIsInclusiveAndUnknownDatesNeverUseCreated() throws {
        let rows=[record("independent/boundary"),record("independent/old"),record("independent/new"),record("independent/unknown"),record("independent/future")]
        let dates=releases(["independent/boundary":"2026-07-16","independent/old":"2026-07-15","independent/new":"2026-11-10","independent/future":"2026-11-17"])
        let result=try OrcaModels.normalize(data(rows),releases:dates,now:today,calendar:calendar)
        XCTAssertEqual(result["cutoffDate"] as? String,"2026-07-16");XCTAssertEqual(result["asOfDate"] as? String,"2026-11-16")
        XCTAssertEqual(Set(models(result).map { $0["id"] as! String }),Set(["independent/boundary","independent/new"]))
        let lateLocal=ISO8601DateFormatter().date(from:"2026-11-17T02:00:00Z")!
        XCTAssertEqual(try OrcaModels.normalize(data(rows),releases:dates,now:lateLocal,calendar:calendar)["asOfDate"] as? String,"2026-11-16")
    }
    func testExcludedProvidersNamesAndAutomaticRoutersNeverEscapeNativeFiltering() throws {
        let ids=["openai/new","anthropic/new","independent/GPT-new","independent/Codex-new","independent/claude-new","orcarouter/auto","vendor/auto","independent/allowed"]
        var rows=ids.map { record($0) };rows.append(record("vendor/hidden",name:"OpenAI compatible model"));rows.append(record("vendor/owner",owner:"Anthropic"))
        let dates=releases(Dictionary(uniqueKeysWithValues:rows.map { ($0["id"] as! String,"2026-10-01") }))
        XCTAssertEqual(models(try OrcaModels.normalize(data(rows),releases:dates,now:today,calendar:calendar)).map { $0["id"] as! String },["independent/allowed"])
    }
    func testOnlyReportedCapabilitiesAreExposedAndNonChatModelsAreHidden() throws {
        let rows=[record("vendor/chat",types:["openai","anthropic"],parameters:["tools"],context:123456),record("vendor/unknown-tools",parameters:nil,context:nil),record("vendor/image",types:["image-generation"]),record("vendor/native-only",types:["gemini"])]
        let dates=releases(Dictionary(uniqueKeysWithValues:rows.map { ($0["id"] as! String,"2026-10-01") }))
        let output=models(try OrcaModels.normalize(data(rows),releases:dates,now:today,calendar:calendar))
        XCTAssertEqual(output.count,2);let chat=output.first { $0["id"] as? String == "vendor/chat" }!,unknown=output.first { $0["id"] as? String == "vendor/unknown-tools" }!
        XCTAssertEqual(chat["tools"] as? Bool,true);XCTAssertEqual(chat["contextLength"] as? Int,123456);XCTAssertEqual(chat["anthropicMessages"] as? Bool,true)
        XCTAssertNil(unknown["tools"]);XCTAssertNil(unknown["contextLength"])
    }
    func testFixedAuthenticatedRequestAndSanitizedErrorsNeverExposeCredential() throws {
        let secret="fixture-sensitive-key",rows=[record("vendor/model")],dates=releases(["vendor/model":"2026-10-01"])
        var calls=0
        let client=OrcaModels(releases:dates,token:{secret},transport:{ request in
            calls += 1;XCTAssertEqual(request.url,OrcaModels.endpoint);XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(request.timeoutInterval,12)
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer "+secret)
            return (try self.data(rows),HTTPURLResponse(url:OrcaModels.endpoint,statusCode:200,httpVersion:nil,headerFields:nil)!)
        },now:{self.today},calendar:calendar)
        let result=try client.catalog();XCTAssertEqual(calls,1);XCTAssertEqual(models(result).count,1);XCTAssertFalse(encode(result).contains(secret))
        let failed=OrcaModels(releases:dates,token:{secret},transport:{_ in throw HUDError(secret)})
        XCTAssertThrowsError(try failed.catalog()) { XCTAssertFalse($0.localizedDescription.contains(secret)) }
        let denied=OrcaModels(releases:dates,token:{throw HUDError(secret)},transport:{_ in XCTFail("no request without credential");throw HUDError("unused")})
        XCTAssertThrowsError(try denied.catalog()) { XCTAssertFalse($0.localizedDescription.contains(secret)) }
    }
    func testRedirectStatusSizeInvalidDatesAndUnsafeIDsFailClosed() throws {
        for (url,status) in [(URL(string:"https://other.example/v1/models")!,200),(OrcaModels.endpoint,302),(OrcaModels.endpoint,401)] {
            let client=OrcaModels(releases:[:],token:{"fake"},transport:{_ in (Data("sensitive body".utf8),HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!)})
            XCTAssertThrowsError(try client.catalog()) { XCTAssertFalse($0.localizedDescription.contains("sensitive body")) }
        }
        let large=OrcaModels(releases:[:],token:{"fake"},transport:{_ in (Data(repeating:32,count:OrcaModels.maximumBytes+1),HTTPURLResponse(url:OrcaModels.endpoint,statusCode:200,httpVersion:nil,headerFields:nil)!)})
        XCTAssertThrowsError(try large.catalog())
        let bad=try OrcaModels.normalize(data([record("vendor/bad"),record("vendor/unsafe;command")]),releases:releases(["vendor/bad":"2026-02-31","vendor/unsafe;command":"2026-10-01"]),now:today,calendar:calendar)
        XCTAssertTrue(models(bad).isEmpty);XCTAssertFalse(OrcaModels.validID("vendor/model\n/model other"))
    }
    func testBundledRegistryHasDatedPrimaryEvidenceAndProducesOnlyAllowedCatalogRows() throws {
        let registry=try OrcaModels.bundledReleases();XCTAssertFalse(registry.isEmpty)
        for (_,entry) in registry { XCTAssertNotNil(entry["releaseDate"] as? String);XCTAssertTrue((entry["sourceURL"] as? String)?.hasPrefix("https://") == true) }
        // A catalog's placeholder-created timestamp is irrelevant to eligibility.
        let first=registry.keys.sorted()[0]
        XCTAssertEqual(models(try OrcaModels.normalize(data([record(first)]),releases:registry,now:today,calendar:calendar)).count,1)
    }
}
