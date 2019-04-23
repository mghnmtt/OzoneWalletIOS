//
//  Notifications.swift
//  O3
//
//  Created by Andrei Terentiev on 4/22/19.
//  Copyright © 2019 O3 Labs Inc. All rights reserved.
//

import Foundation
import Neoutils

//Need to be generated by activating the inbox
public struct O3KeyPair {
    static let privateKey: String = "abcxyz"
    static let pubkey: String = "abcxyz"
}

public struct NotificationSubscriptionUnsignedRequest: Encodable {
    var timestamp: String
    var service: String
    var topic: String
    
    enum CodingKeys: String, CodingKey {
        case timestamp
        case service
        case topic
    }
    
    public init(timestamp: String, service: String, topic: String) {
        self.timestamp = timestamp
        self.service = service
        self.topic = topic
    }
}

public struct NotificationSubscriptionSignedRequest: Encodable {
    var data: NotificationSubscriptionUnsignedRequest
    var signature: String
    
    enum CodingKeys: String, CodingKey {
        case data
        case signature
    }
    
    public init(data: NotificationSubscriptionUnsignedRequest, signature: String) {
        self.data = data
        self.signature = signature
    }
}

public struct MessagesUnsignedRequest: Encodable {
    var timestamp: String
    
    enum CodingKeys: String, CodingKey {
       case timestamp
    }
    
    public init(timestamp: String) {
        self.timestamp = timestamp
    }
}

public struct MessagesSignedRequest: Encodable {
    var data: MessagesUnsignedRequest
    var signature: String
    
    enum CodingKeys: String, CodingKey {
        case data
        case signature
    }
    
    public init(data: MessagesUnsignedRequest, signature: String) {
        self.data = data
        self.signature = signature
    }
}

public struct Message: Codable {
    var id: String
    var title: String
    var timestamp: String
    var channel: Channel
    var action: Action
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case timestamp
        case channel
        case action
    }
    
    public init(id: String, title: String, timestamp: String, channel: Channel, action: Action) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.channel = channel
        self.action = action
    }

    
    public struct Channel: Codable {
        var service: String
        var topic: String
    
        enum CodingKeys: String, CodingKey {
            case service
            case topic
        }
        
        public init(service: String, topic: String) {
            self.service = service
            self.topic = topic
        }
    }
    
    public struct Action: Codable {
        var type: String
        var title: String
        var url: String
        
        enum CodingKeys: String, CodingKey {
            case type
            case title
            case url
        }
        
        public init(type: String, title: String, url: String) {
            self.type = type
            self.title = title
            self.url = url
        }
    }
}

extension O3APIClient {
    func subscribeToTopic(service: String, topic: String, completion: @escaping(O3APIClientResult<Bool>) -> Void) {
        let endpoint = "/v1/nc/\(O3KeyPair.pubkey)/subscribe"
    
        let timestamp = String(Date().timeIntervalSince1970)
        let objectToSign = NotificationSubscriptionUnsignedRequest(timestamp: timestamp, service: service, topic: topic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let dataToSign = try? encoder.encode(objectToSign)
        
        
        var error: NSError?
        let signature = (NeoutilsSign(dataToSign, O3KeyPair.privateKey, &error)?.fullHexString)!
        
        let signedObject = NotificationSubscriptionSignedRequest(data: objectToSign, signature: signature)
        let signedData = try! encoder.encode(signedObject)
        
        sendRESTAPIRequest(endpoint, data: signedData, requestType: "POST") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let success = O3APIClientResult.success(true)
                completion(success)
            }
        }
    }
    
    func unsubscribeToTopic(service: String, topic: String, completion: @escaping(O3APIClientResult<Bool>) -> Void) {
        let endpoint = "/v1/nc/\(O3KeyPair.pubkey)/unsubscribe"
        
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let timestamp = String(Date().timeIntervalSince1970)
        let objectToSign = NotificationSubscriptionUnsignedRequest(timestamp: timestamp, service: service, topic: topic)
        let dataToSign = try? encoder.encode(objectToSign)
        
        var error: NSError?
        let signature = (NeoutilsSign(dataToSign, O3KeyPair.privateKey, &error)?.fullHexString)!
        
        let signedObject = NotificationSubscriptionSignedRequest(data: objectToSign, signature: signature)
        let signedData = try! encoder.encode(signedObject)
        
        sendRESTAPIRequest(endpoint, data: signedData, requestType: "POST") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let success = O3APIClientResult.success(true)
                completion(success)
            }
        }
    }
    
    func getMessages(pubKey: String, page: Int, completion: @escaping(O3APIClientResult<[Message]>) -> Void) {
        let endpoint = "/v1/nc/\(O3KeyPair.pubkey)"
        let params = ["page": page]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let timestamp = String(Date().timeIntervalSince1970)
        let objectToSign = MessagesUnsignedRequest(timestamp: timestamp)
        let dataToSign = try? encoder.encode(objectToSign)
        
        var error: NSError?
        let signature = (NeoutilsSign(dataToSign, O3KeyPair.privateKey, &error)?.fullHexString)!
        
        let signedObject = MessagesSignedRequest(data: objectToSign, signature: signature)
        let signedData =  try! encoder.encode(signedObject)
        
        sendRESTAPIRequest(endpoint, data: signedData, requestType: "POST") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let decoder = JSONDecoder()
                guard let dictionary = response["result"] as? JSONDictionary,
                    let data = try? JSONSerialization.data(withJSONObject: dictionary["data"] as Any, options: .prettyPrinted),
                    let messages = try? decoder.decode([Message].self, from: data) else {
                        completion(.failure(O3APIClientError.invalidData))
                        return
                }
                completion(.success(messages))
            }
        }
    }
}