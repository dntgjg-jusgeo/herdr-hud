import Foundation
import CoreFoundation
import CryptoKit

/// A managed, dedicated OpenCode 2.1.4 server. Never sends terminal input or
/// retries a mutation. Call from the owner's serial background queue.
final class OrcaOpenCode {
    struct Failure: LocalizedError {
        let message: String
        let uncertain: Bool
        var errorDescription: String? { message }
    }
    typealias Transport = (URLRequest) throws -> (Data, HTTPURLResponse)
    static let version = "2.1.4"
    // The durable prompt acknowledgement includes the accepted image bytes.
    static let maximumResponseBytes = 18 * 1024 * 1024
    let endpoint: URL
    let serverPID: Int
    let sessionID: String
    let modelID: String
    let providerID: String
    let directory: String
    private let secret: String
    private let transport: Transport
    private(set) var uncertain = false

    init(endpoint: URL, password: String, serverPID: Int, sessionID: String,
         modelID: String, directory: String, providerID:String = "orcarouter", transport: @escaping Transport = OrcaOpenCode.fetch) throws {
        guard Self.validEndpoint(endpoint), serverPID > 0,
              sessionID.range(of:"^ses[A-Za-z0-9_-]{1,100}$",options:.regularExpression) != nil,
              OrcaModels.validID(modelID),providerID.range(of:"^[A-Za-z0-9_-]{1,100}$",options:.regularExpression) != nil,directory.hasPrefix("/"),directory.utf8.count <= 4096,
              directory.rangeOfCharacter(from:.controlCharacters) == nil,
              password.utf8.count >= 32,password.utf8.count <= 256,
              password.rangeOfCharacter(from:.controlCharacters) == nil else { throw Self.refusal("Invalid managed OpenCode connection.") }
        self.endpoint=endpoint;secret=password;self.serverPID=serverPID;self.sessionID=sessionID
        self.modelID=modelID;self.providerID=providerID;self.directory=directory;self.transport=transport
    }
    static func password(token: String, nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for:Data(("herdr-hud/opencode/v1/"+nonce).utf8),using:SymmetricKey(data:Data(token.utf8))).map { String(format:"%02x",$0) }.joined()
    }
    static func validEndpoint(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && (url.port.map { (1024...65535).contains($0) } ?? false)
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && ["","/"].contains(url.path)
    }
    private static func refusal(_ text: String) -> Failure { Failure(message:text,uncertain:false) }
    private static func unknown() -> Failure { Failure(message:"OpenCode delivery is uncertain. Check this chat in Herdr before reconciling; do not resend automatically.",uncertain:true) }
    private static func integer(_ value: Any?) -> Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,
              n.doubleValue.rounded(.down) == n.doubleValue,n.doubleValue > 0,n.doubleValue <= Double(Int32.max) else { return nil };return n.intValue
    }
    private static func call(endpoint:URL,password:String,method:String,path:String,body:Row?,transport:Transport) throws -> Row {
        guard validEndpoint(endpoint),path.hasPrefix("/api/"), !path.contains("#") else { throw refusal("Invalid managed OpenCode request.") }
        let url=URL(string:path,relativeTo:endpoint)!.absoluteURL
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:5)
        request.httpMethod=method;request.setValue("Basic "+Data(("opencode:"+password).utf8).base64EncodedString(),forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if let body { request.httpBody=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes]);request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        guard (request.httpBody?.count ?? 0) <= 18 * 1024 * 1024 else { throw refusal("OpenCode prompt exceeds its size limit.") }
        let bytes:Data,response:HTTPURLResponse
        do { (bytes,response)=try transport(request) } catch { throw refusal("The managed OpenCode server is unavailable.") }
        guard response.url == url,response.statusCode == 200,bytes.count <= maximumResponseBytes,
              let value=try? JSONSerialization.jsonObject(with:bytes) as? Row else { throw refusal("The managed OpenCode server returned an unsupported or refused response.") }
        return value
    }
    private func call(_ method:String,_ path:String,_ body:Row? = nil) throws -> Row {
        try Self.call(endpoint:endpoint,password:secret,method:method,path:path,body:body,transport:transport)
    }
    private static func checkInfo(_ info:Row,pid:Int? = nil) throws -> Int {
        guard info["version"] as? String == version,let actual=integer(info["pid"]),pid == nil || pid == actual else { throw refusal("The managed OpenCode server changed or has an unsupported version.") };return actual
    }
    private static func checkSession(_ row:Row,id:String,model:String,directory:String,providerID:String) throws {
        guard row["id"] as? String == id,let ref=row["model"] as? Row,ref["providerID"] as? String == providerID,ref["id"] as? String == model,
              let location=row["location"] as? Row,location["directory"] as? String == directory,
              let time=row["time"] as? Row,time["archived"] == nil || time["archived"] is NSNull else { throw refusal("This OpenCode chat, model, or directory changed. Use its terminal or open a new managed chat.") }
    }
    /// Bootstrap only: creates an empty session, never a provider turn. Caller
    /// must never retry after an error without checking the dedicated server.
    static func create(endpoint:URL,password:String,sessionID:String,modelID:String,directory:String,providerID:String = "orcarouter",expectedServerPID:Int? = nil,
                       transport:@escaping Transport = OrcaOpenCode.fetch) throws -> Int {
        let info=try call(endpoint:endpoint,password:password,method:"GET",path:"/api/info",body:nil,transport:transport)
        let pid=try checkInfo(info,pid:expectedServerPID)
        let adapter = try OrcaOpenCode(endpoint:endpoint,password:password,serverPID:pid,sessionID:sessionID,modelID:modelID,directory:directory,providerID:providerID,transport:transport)
        try adapter.verifyCatalog()
        do {
            let reply=try call(endpoint:endpoint,password:password,method:"POST",path:"/api/session",body:["id":sessionID,"title":"OrcaRouter · "+modelID,"model":["providerID":providerID,"id":modelID],"location":["directory":directory]],transport:transport)
            guard let row=reply["data"] as? Row else { throw unknown() }
            try checkSession(row,id:sessionID,model:modelID,directory:directory,providerID:providerID)
            return pid
        } catch { throw unknown() }
    }
    /// A fresh provider namespace must expose only the selected model. Built-in
    /// Orca's broad catalog is never accepted as a model pin.
    func verifyCatalog(requireVision:Bool = false) throws {
        var query=URLComponents();query.queryItems=[URLQueryItem(name:"location[directory]",value:directory)]
        let suffix="?"+(query.percentEncodedQuery ?? "")
        let catalog=try call("GET","/api/model"+suffix)
        guard let location=catalog["location"] as? Row,location["directory"] as? String == directory,
              let models=catalog["data"] as? [Row],models.count == 1,
              models[0]["id"] as? String == modelID,models[0]["modelID"] as? String == modelID,
              models[0]["providerID"] as? String == providerID,models[0]["enabled"] as? Bool == true else { throw Self.refusal("This managed OpenCode server must expose only the selected OrcaRouter model.") }
        if requireVision {
            guard ((models[0]["capabilities"] as? Row)?["input"] as? [String])?.contains("image") == true else { throw Self.refusal("This OpenCode model has no verified image input. Open a new vision-capable OrcaRouter chat from the HUD before sending images or videos. Your draft is retained.") }
        }
        // model.list waits for initial plugin settlement; provider.list alone
        // can return an empty snapshot before that boundary.
        let providers=try call("GET","/api/provider"+suffix)
        guard let providerLocation=providers["location"] as? Row,providerLocation["directory"] as? String == directory,
              let rows=providers["data"] as? [Row],rows.count == 1,rows[0]["id"] as? String == providerID,
              rows[0]["package"] as? String == "@opencode/ai/providers/openai-compatible",
              let settings=rows[0]["settings"] as? Row,settings["baseURL"] as? String == "https://api.orcarouter.ai/v1" else { throw Self.refusal("This managed OpenCode server must use only its dedicated OrcaRouter provider.") }
    }
    /// Bounded read-only requests; no event-stream inference or screen parsing.
    func snapshot() throws -> Row {
        _ = try Self.checkInfo(call("GET","/api/info"),pid:serverPID)
        try verifyCatalog()
        let roots=try call("GET","/api/session?parentID=null&limit=2")
        guard let rows=roots["data"] as? [Row],rows.count == 1,rows[0]["id"] as? String == sessionID,
              let cursor=roots["cursor"] as? Row else { throw Self.refusal("Terminal changed chats. Use its terminal or open a new managed chat.") }
        // V2 returns boundary cursors even on the final nonempty page. Prove
        // exhaustion rather than treating a nonnull cursor as another session.
        if let next=cursor["next"],!(next is NSNull) {
            guard let token=next as? String,!token.isEmpty,token.utf8.count <= 8192 else { throw Self.refusal("OpenCode session pagination is unsupported.") }
            var query=URLComponents();query.queryItems=[URLQueryItem(name:"parentID",value:"null"),URLQueryItem(name:"limit",value:"2"),URLQueryItem(name:"cursor",value:token)]
            let continuation=try call("GET","/api/session?"+(query.percentEncodedQuery ?? ""))
            guard let tail=continuation["data"] as? [Row],tail.isEmpty,let end=continuation["cursor"] as? Row,
                  end["next"] == nil || end["next"] is NSNull else { throw Self.refusal("Terminal changed chats. Use its terminal or open a new managed chat.") }
        }
        try Self.checkSession(rows[0],id:sessionID,model:modelID,directory:directory,providerID:providerID)
        let active=try call("GET","/api/session/active")
        guard let states=active["data"] as? [String:Row],states.count <= 256,
              states.values.allSatisfy({ $0["type"] as? String == "running" }) else { throw Self.refusal("OpenCode activity is unavailable.") }
        let permissions=try call("GET","/api/session/"+sessionID+"/permission")
        let forms=try call("GET","/api/session/"+sessionID+"/form")
        guard let pending=permissions["data"] as? [Row],let questions=forms["data"] as? [Row],pending.count <= 128,questions.count <= 128,
              (pending+questions).allSatisfy({ $0["sessionID"] as? String == sessionID }) else { throw Self.refusal("OpenCode pending input is unavailable.") }
        let blocked = !pending.isEmpty || !questions.isEmpty
        let state=blocked ? "blocked" : states[sessionID] == nil ? "idle" : "working"
        return ["connected":true,"sessionID":sessionID,"modelID":modelID,"agent_status":state,"input_kind":blocked ? (!pending.isEmpty ? "permission":"question") : "",
                "canPrompt":state == "idle" && !uncertain,"canQueue":!blocked && !uncertain,"uncertain":uncertain]
    }
    func reconcile() throws -> Row {
        var state=try snapshot();uncertain=false;state["uncertain"]=false
        state["canPrompt"]=state["agent_status"] as? String == "idle"
        state["canQueue"]=state["agent_status"] as? String != "blocked"
        return state
    }
    /// The queue endpoint admits exactly one input and returns a durable inbox
    /// record. Even a refusal or malformed response after dispatch is uncertain.
    func prompt(text:String,attachments:[ImageAttachment] = []) throws -> Row {
        guard !uncertain else { throw Self.refusal("Check the uncertain OpenCode delivery in Herdr and reconcile before sending again.") }
        guard text.utf8.count <= 60000,!text.contains("\0"),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              attachments.count <= ImageAttachment.maximumCount else { throw Self.refusal("Enter a prompt under 60 KB with at most three images.") }
        var files:[Row]=[]
        for image in attachments {
            let checked=try ImageAttachment.parse([["data":image.data.base64EncodedString()]]).first!
            let mime=checked.name.lowercased().hasSuffix(".png") ? "image/png" : checked.name.lowercased().hasSuffix(".gif") ? "image/gif" : checked.name.lowercased().hasSuffix(".webp") ? "image/webp" : "image/jpeg"
            files.append(["uri":"data:"+mime+";base64,"+checked.data.base64EncodedString(),"name":checked.name])
        }
        if !attachments.isEmpty {try verifyCatalog(requireVision:true)}
        let current=try snapshot()
        guard current["canQueue"] as? Bool == true else { throw Self.refusal("This OpenCode chat needs input in its terminal before accepting a prompt.") }
        let id="msg_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        do {
            let reply=try call("POST","/api/session/"+sessionID+"/prompt",["id":id,"text":text,"files":files,"delivery":"queue"])
            guard let row=reply["data"] as? Row,row["id"] as? String == id,row["sessionID"] as? String == sessionID,row["type"] as? String == "user",row["delivery"] as? String == "queue",
                  let payload=row["payload"] as? Row,payload["text"] as? String == text else { throw Self.unknown() }
            let acceptedFiles=payload["files"] as? [Row] ?? []
            guard acceptedFiles.count == files.count,zip(acceptedFiles,files).allSatisfy({ file,expected in
                guard let data=file["data"] as? String,!data.isEmpty,data.utf8.count <= 6 * 1024 * 1024,
                      let mime=file["mime"] as? String,["image/png","image/jpeg","image/webp","image/gif"].contains(mime),
                      let source=file["source"] as? Row,source["type"] as? String == "inline",
                      let sent=expected["uri"] as? String,sent == "data:"+mime+";base64,"+data else { return false };return true
            }) else { throw Self.unknown() }
            return ["ok":true,"accepted":true,"sessionID":sessionID,"messageID":id]
        } catch { uncertain=true;throw Self.unknown() }
    }
    static func fetch(_ request:URLRequest) throws -> (Data,HTTPURLResponse) {
        guard let url=request.url,let origin=URL(string:"http://127.0.0.1:\(url.port ?? 0)"),validEndpoint(origin),url.host == "127.0.0.1",url.scheme == "http" else { throw refusal("Unsupported OpenCode endpoint.") }
        let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.urlCredentialStorage=nil;config.httpCookieStorage=nil
        config.httpShouldSetCookies=false;config.connectionProxyDictionary=[:];config.timeoutIntervalForRequest=5;config.timeoutIntervalForResource=6
        let delegate=Response(),queue=OperationQueue();queue.maxConcurrentOperationCount=1
        let session=URLSession(configuration:config,delegate:delegate,delegateQueue:queue);defer { session.invalidateAndCancel() }
        let task=session.dataTask(with:request);task.resume()
        guard delegate.done.wait(timeout:.now()+7) == .success,!delegate.failed,let response=delegate.response else { task.cancel();throw refusal("OpenCode request timed out or failed.") }
        return (delegate.data,response)
    }
    private final class Response:NSObject,URLSessionDataDelegate {
        let done=DispatchSemaphore(value:0);var data=Data(),response:HTTPURLResponse?,failed=false
        func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { failed=true;completionHandler(nil) }
        func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
            guard let http=response as? HTTPURLResponse,response.expectedContentLength <= Int64(OrcaOpenCode.maximumResponseBytes) else { failed=true;completionHandler(.cancel);return };self.response=http;completionHandler(.allow)
        }
        func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
            guard self.data.count+data.count <= OrcaOpenCode.maximumResponseBytes else { failed=true;dataTask.cancel();return };self.data.append(data)
        }
        func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) { if error != nil { failed=true };done.signal() }
    }
}
