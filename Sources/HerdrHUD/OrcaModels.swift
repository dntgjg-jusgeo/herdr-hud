import Foundation
import CoreFoundation
import Security
import LocalAuthentication

/// Catalog metadata only. Credentials never leave the native HTTPS request;
/// neither a generation request nor an existing-session model command is sent.
final class OrcaModels {
    static let endpoint = URL(string:"https://api.orcarouter.ai/v1/models")!
    static let maximumBytes = 2 * 1024 * 1024
    typealias Transport = (URLRequest) throws -> (Data, HTTPURLResponse)
    private let releases: [String:Row]?
    private let token: () throws -> String
    private let transport: Transport
    private let now: () -> Date
    private let calendar: Calendar

    init(releases: [String:Row]? = nil, token: @escaping () throws -> String = OrcaModels.keychainToken,
         transport: @escaping Transport = OrcaModels.fetch, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.releases=releases;self.token=token;self.transport=transport;self.now=now;self.calendar=calendar
    }
    private static func failure(_ message: String = "OrcaRouter model catalog is unavailable. Refresh to try again.") -> HUDError { HUDError(message) }
    static func keychainToken() throws -> String {
        let context=LAContext();context.interactionNotAllowed=true
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:"ORCAROUTER_AUTH_TOKEN",kSecAttrAccount as String:NSUserName(),
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,
            kSecUseAuthenticationContext as String:context]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value) == errSecSuccess,
              let bytes=value as? Data,let token=String(data:bytes,encoding:.utf8),!token.isEmpty else {
            throw failure("The saved OrcaRouter token is unavailable in Keychain. Check its access, then refresh; do not replace it because of a sandbox error.")
        }
        return token
    }
    func catalog() throws -> Row {
        let secret: String
        do { secret=try token() } catch { throw Self.failure("The saved OrcaRouter token is unavailable in Keychain. Check its access, then refresh.") }
        guard !secret.isEmpty,secret.utf8.count <= 8192,
              secret.rangeOfCharacter(from:.whitespacesAndNewlines) == nil,
              secret.rangeOfCharacter(from:.controlCharacters) == nil else { throw Self.failure("The saved OrcaRouter credential is invalid. Check Keychain before refreshing.") }
        var request=URLRequest(url:Self.endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:12)
        request.httpMethod="GET";request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Accept")
        let data: Data, response: HTTPURLResponse
        do { (data,response)=try transport(request) } catch { throw Self.failure() }
        guard response.url == Self.endpoint else { throw Self.failure("OrcaRouter redirects are not accepted.") }
        guard response.statusCode == 200 else { throw Self.failure("OrcaRouter catalog request was refused (HTTP \(response.statusCode)).") }
        guard data.count <= Self.maximumBytes else { throw Self.failure("OrcaRouter catalog exceeds its size limit.") }
        return try Self.normalize(data,releases:try releases ?? Self.bundledReleases(),now:now(),calendar:calendar)
    }
    static func bundledReleases() throws -> [String:Row] {
        let file=try FileHandle(forReadingFrom:HUDResources.root.appendingPathComponent("orca-releases.json"));defer { try? file.close() }
        guard let data=try file.read(upToCount:262145),data.count <= 262144,
              let root=try JSONSerialization.jsonObject(with:data) as? Row,root["version"] as? Int == 1,
              let models=root["models"] as? [String:Row],models.count <= 1024 else { throw failure("The verified OrcaRouter release registry is unavailable.") }
        return models
    }
    static func validID(_ id: String) -> Bool {
        id.range(of:"^[A-Za-z0-9][A-Za-z0-9._:/@+\\-]{0,199}$",options:.regularExpression) != nil
    }
    private static func excluded(id: String, name: String, owner: String) -> Bool {
        let values=[id,name,owner].map { $0.lowercased() },combined=values.joined(separator:" ")
        if ["openai","anthropic","gpt","codex","claude"].contains(where:combined.contains) { return true }
        let parts=id.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted)
        return parts.contains(where:["auto","router","routing","default","best","balanced"].contains)
            || id.lowercased().hasPrefix("orcarouter/") || owner.lowercased().contains("router")
            || name.lowercased().contains("auto router") || name.lowercased().contains("automatic routing")
    }
    static func normalize(_ data: Data, releases: [String:Row], now: Date, calendar: Calendar = .current) throws -> Row {
        guard data.count <= maximumBytes else { throw failure("OrcaRouter catalog exceeds its size limit.") }
        let root: Row
        do { guard let value=try JSONSerialization.jsonObject(with:data) as? Row else { throw failure() };root=value } catch { throw failure() }
        guard let records=root["data"] as? [Row],records.count <= 4096 else { throw failure() }
        var local=Calendar(identifier:.gregorian);local.timeZone=calendar.timeZone
        var utc=Calendar(identifier:.gregorian);utc.timeZone=TimeZone(secondsFromGMT:0)!
        let components=local.dateComponents([.year,.month,.day],from:now)
        guard let today=utc.date(from:components),let cutoff=utc.date(byAdding:.month,value:-4,to:today) else { throw failure() }
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=utc;formatter.timeZone=utc.timeZone;formatter.dateFormat="yyyy-MM-dd";formatter.isLenient=false
        var models:[Row]=[],seen=Set<String>()
        for record in records {
            guard let id=record["id"] as? String,validID(id),seen.insert(id).inserted else { continue }
            let supplied=record["name"] as? String ?? id
            let name = !supplied.isEmpty && supplied.utf8.count <= 512 && supplied.rangeOfCharacter(from:.controlCharacters) == nil ? supplied : id
            let owner=record["owned_by"] as? String ?? ""
            guard !excluded(id:id,name:name,owner:owner),let release=releases[id],
                  let date=release["releaseDate"] as? String,date.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}$",options:.regularExpression) != nil,
                  let published=formatter.date(from:date),formatter.string(from:published) == date,published >= cutoff,published <= today,
                  let source=release["sourceURL"] as? String,source.utf8.count <= 2048,
                  let url=URL(string:source),url.scheme == "https",url.host != nil,url.user == nil,url.password == nil else { continue }
            let types=record["supported_endpoint_types"] as? [String] ?? [],capabilities=record["endpoint_capabilities"] as? [String] ?? []
            let chat=types.contains(where:["openai","anthropic","gemini"].contains) || capabilities.contains(where:["chat_completions","anthropic_messages","gemini_generate","openai_responses"].contains)
            let openAIChat=types.contains("openai") || capabilities.contains("chat_completions")
            guard chat,openAIChat else { continue }
            var model: Row=["id":id,"name":name,"releaseDate":date,"releaseSource":source,"chat":true,"openAIChat":true,
                "anthropicMessages":types.contains("anthropic") || capabilities.contains("anthropic_messages")]
            model["vision"] = ((record["architecture"] as? Row)?["input_modalities"] as? [String])?.contains("image") == true
            if let parameters=record["supported_parameters"] as? [String],parameters.contains("tools") { model["tools"]=true }
            if let context=record["context_length"] as? NSNumber,CFGetTypeID(context) != CFBooleanGetTypeID(),
               context.doubleValue > 0,context.doubleValue <= 1_000_000_000,context.doubleValue.rounded(.down) == context.doubleValue { model["contextLength"]=context }
            if let output=record["max_completion_tokens"] as? NSNumber,CFGetTypeID(output) != CFBooleanGetTypeID(),
               output.doubleValue > 0,output.doubleValue <= 1_000_000_000,output.doubleValue.rounded(.down) == output.doubleValue { model["outputLength"]=output }
            models.append(model)
        }
        models.sort { ($0["name"] as! String).localizedStandardCompare($1["name"] as! String) == .orderedAscending }
        return ["models":models,"cutoffDate":formatter.string(from:cutoff),"asOfDate":formatter.string(from:today),"source":endpoint.absoluteString]
    }
    static func fetch(_ request: URLRequest) throws -> (Data,HTTPURLResponse) {
        guard request.url == endpoint,request.httpMethod == "GET" else { throw failure() }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.urlCache=nil;configuration.urlCredentialStorage=nil;configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData;configuration.timeoutIntervalForRequest=12;configuration.timeoutIntervalForResource=12
        let delegate=CatalogResponse(),queue=OperationQueue();queue.maxConcurrentOperationCount=1
        let session=URLSession(configuration:configuration,delegate:delegate,delegateQueue:queue);defer { session.invalidateAndCancel() }
        let task=session.dataTask(with:request);task.resume()
        guard delegate.completed.wait(timeout:.now()+15) == .success else { task.cancel();throw failure() }
        guard !delegate.failed,let response=delegate.response else { throw failure() }
        return (delegate.data,response)
    }
    private final class CatalogResponse: NSObject, URLSessionDataDelegate {
        let completed=DispatchSemaphore(value:0)
        var data=Data(),response:HTTPURLResponse?,failed=false
        func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
        func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
            guard let http=response as? HTTPURLResponse,http.url == OrcaModels.endpoint,
                  response.expectedContentLength <= Int64(OrcaModels.maximumBytes) else { failed=true;completionHandler(.cancel);return }
            self.response=http;completionHandler(.allow)
        }
        func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
            guard self.data.count+data.count <= OrcaModels.maximumBytes else { failed=true;dataTask.cancel();return };self.data.append(data)
        }
        func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) { if error != nil { failed=true };completed.signal() }
    }
}
