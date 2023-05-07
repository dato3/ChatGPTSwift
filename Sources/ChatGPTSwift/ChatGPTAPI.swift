//
//  ChatGPTAPI.swift
//  XCAChatGPT
//
//  Created by Nursultan Zhiyembay on 01/02/23.
//

import Foundation
import GPTEncoder

public class ChatGPTAPI: NSObject, @unchecked Sendable {
  
    public var streamDataTask: URLSessionDataTask?
    
    public enum Constants {
        public static let defaultSystemText = "You're a helpful assistant"
    }
    
    private let urlString = "https://streamingwords-53f47dwjva-uc.a.run.app"
    private let gptEncoder = GPTEncoder()
    public private(set) var historyList = [Message]()

    let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "YYYY-MM-dd"
        return df
    }()
    
    private let jsonDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        return jsonDecoder
    }()
    
    private var headers: [String: String] {
        [
            "Content-Type": "application/json"
        ]
    }
    
    private func systemMessage(content: String) -> Message {
        .init(role: "system", content: content)
    }
    
    private func generateMessages(from text: String, systemText: String) -> [Message] {
        var messages = [systemMessage(content: systemText)] + historyList + [Message(role: "user", content: text)]
        if gptEncoder.encode(text: messages.content).count > 4096  {
            _ = historyList.removeFirst()
            messages = generateMessages(from: text, systemText: systemText)
        }
        return messages
    }
    
    private func jsonBody(text: String, systemText: String, limit: Int) throws -> Data {
        let request = Request(msg: generateMessages(from: text, systemText: systemText), limit: limit)
        return try JSONEncoder().encode(request)
    }
    
    private func appendToHistoryList(userText: String, responseText: String) {
        self.historyList.append(Message(role: "user", content: userText))
        self.historyList.append(Message(role: "assistant", content: responseText))
    }

    private let urlSession = URLSession.shared
    private var urlRequest: URLRequest {
        let url = URL(string: urlString)!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        headers.forEach {  urlRequest.setValue($1, forHTTPHeaderField: $0) }
        return urlRequest
    }

    public func sendMessageStream(text: String,
                                  systemText: String = ChatGPTAPI.Constants.defaultSystemText,
                                  limit: Int) async throws -> AsyncThrowingStream<String, Error> {
        var urlRequest = self.urlRequest
        urlRequest.httpBody = try jsonBody(text: text, systemText: systemText, limit: limit)
        let (result, response) = try await urlSession.bytes(for: urlRequest, delegate: self)
        streamDataTask = result.task
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw "Invalid response"
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            var errorText = ""
            for try await line in result.lines {
               errorText += line
            }
            if let data = errorText.data(using: .utf8), let errorResponse = try? jsonDecoder.decode(ErrorRootResponse.self, from: data).error {
                errorText = "\n\(errorResponse.message)"
            }
            throw "Bad Response: \(httpResponse.statusCode). \(errorText)"
        }
        
        return AsyncThrowingStream<String, Error> {  continuation in
            Task(priority: .userInitiated) { [weak self] in
                do {
                    var responseText = ""
                    for try await line in result.lines {
                      if line.starts(with: "data: ") {
                        let text = String(line.dropFirst(6))
                        responseText += text
                        continuation.yield(text)
                      }
                    }
                    self?.appendToHistoryList(userText: text, responseText: responseText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    public func deleteHistoryList() {
        self.historyList.removeAll()
    }
    
    public func replaceHistoryList(with messages: [Message]) {
        self.historyList = messages
    }
    
}

extension ChatGPTAPI: URLSessionTaskDelegate {
  public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard let serverTrust = challenge.protectionSpace.serverTrust,
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.cancelAuthenticationChallenge, nil)
    }

    //Set policy to validate domain
    let policy = SecPolicyCreateSSL(true, "streamingwords-53f47dwjva-uc.a.run.app" as CFString)
    let policies = NSArray(object: policy)
    SecTrustSetPolicies(serverTrust, policies)

    let certificateCount = SecTrustGetCertificateCount(serverTrust)
    guard certificateCount > 0 else {
      return (.cancelAuthenticationChallenge, nil)
    }
    let certificates = Set((0..<certificateCount)
    .compactMap({  SecTrustGetCertificateAtIndex(serverTrust, $0) })
    .map { SecCertificateCopyData($0) as Data })

    let localCertificates = Set(Certificate.localCertificates())
    let isDisjoint = !certificates.isDisjoint(with: localCertificates)
    if isDisjoint {
      return (.useCredential, .init(trust: serverTrust))
    }

    // No valid cert available
    return (.cancelAuthenticationChallenge, nil)
  }
}

struct Certificate {
    let certificate: SecCertificate
    let data: Data
}

extension Certificate {
    static func localCertificates(with names: [String] = ["g1sr"],
                                  from bundle: Bundle = .main) -> [Data] {
        return names.lazy.map({
            guard let file = bundle.url(forResource: $0, withExtension: "der"),
                let data = try? Data(contentsOf: file) else {
                    return nil
            }
            return data
        }).flatMap({$0})
    }
}
