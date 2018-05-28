//
//  Account.swift
//  NeoSwift
//
//  Created by Andrei Terentiev on 8/25/17.
//  Copyright © 2017 drei. All rights reserved.
//

import Foundation
import Neoutils
import Security

public class Account {
    public var wif: String
    public var publicKey: Data
    public var privateKey: Data
    public var address: String
    public var hashedSignature: Data

    lazy var publicKeyString: String = {
        return publicKey.fullHexString
    }()

    lazy var privateKeyString: String = {
        return privateKey.fullHexString
    }()

    public init?(wif: String) {
        var error: NSError?
        guard let wallet = NeoutilsGenerateFromWIF(wif, &error) else { return nil }
        self.wif = wif
        self.publicKey = wallet.publicKey()
        self.privateKey = wallet.privateKey()
        self.address = wallet.address()
        self.hashedSignature = wallet.hashedSignature()
    }

    public init?(privateKey: String) {
        var error: NSError?
        guard let wallet = NeoutilsGenerateFromPrivateKey(privateKey, &error) else { return nil }
        self.wif = wallet.wif()
        self.publicKey = wallet.publicKey()
        self.privateKey = privateKey.dataWithHexString()
        self.address = wallet.address()
        self.hashedSignature = wallet.hashedSignature()
    }

    public init?() {
        var pkeyData = Data(count: 32)
        let result = pkeyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, pkeyData.count, $0)
        }

        if result != errSecSuccess {
            fatalError()
        }

        var error: NSError?
        guard let wallet = NeoutilsGenerateFromPrivateKey(pkeyData.fullHexString, &error) else { return nil }
        self.wif = wallet.wif()
        self.publicKey = wallet.publicKey()
        self.privateKey = pkeyData
        self.address = wallet.address()
        self.hashedSignature = wallet.hashedSignature()
    }

    func createSharedSecret(publicKey: Data) -> Data? {
        var error: NSError?
        guard let wallet = NeoutilsGenerateFromPrivateKey(self.privateKey.fullHexString, &error) else {return nil}
        return wallet.computeSharedSecret(publicKey)
    }

    func encryptString(key: Data, text: String) -> String {
        return NeoutilsEncrypt(key, text)
    }

    func decryptString(key: Data, text: String) -> String? {
        return NeoutilsDecrypt(key, text)
    }

    /*
     * Every asset has a list of transaction ouputs representing the total balance
     * For example your total NEO could be represented as a list [tx1, tx2, tx3]
     * and each element contains an individual amount. So your total balance would
     * be represented as SUM([tx1.amount, tx2.amount, tx3.amount]) In order to make
     * a new transaction we will need to find which inputs are necessary in order to
     * satisfy the condition that SUM(Inputs) >= amountToSend
     *
     * We will attempt to get rid of the the smallest inputs first. So we will sort
     * the list of unspents in ascending order, and then keep a running sum until we
     * meet the condition SUM(Inputs) >= amountToSend. If the SUM(Inputs) == amountToSend 
     * then we will have one transaction output since no change needs to be returned
     * to the sender. If Sum(Inputs) > amountToSend then we will need two transaction
     * outputs, one that sends the amountToSend to the reciever and one that sends
     * Sum(Inputs) - amountToSend back to the sender, thereby returning the change.
     *
     * Input Payload Structure (where each Transaction Input is 34 bytes ). Let n be the
     * number of input transactions necessary | Inputs.count | Tx1 | Tx2 |....| Txn |
     *
     *
     *                             * Input Data Detailed View *
     * |    1 byte    |         32 bytes         |       2 bytes     | 34 * (n - 2) | 34 bytes |
     * | Inputs.count | TransactionId (Reversed) | Transaction Index | ............ |   Txn    |
     *
     *
     *
     *                                               * Final Payload *
     * | 3 bytes  |    1 + (n * 34) bytes     | 1 byte | 32 bytes |     16 bytes (Int64)     |       32 bytes        |
     * | 0x800000 | Input Data Detailed Above |  0x02  |  assetID | toSendAmount * 100000000 | reciever address Hash |
     *
     *
     * |                    16 bytes (Int64)                    |       32 bytes      |  3 bytes |
     * | (totalAmount * 100000000) - (toSendAmount * 100000000) | sender address Hash | 0x014140 |
     *
     *
     * |    32 bytes    |      34 bytes        |
     * | Signature Data | NeoSigned public key |
     *
     * NEED TO DOUBLE CHECK THE BYTE COUNT HERE
     */
    public func getInputsNecessaryToSendAsset(asset: AssetId, amount: Double, assets: Assets?) -> (totalAmount: Decimal?, payload: Data?, error: Error?) {

        //asset less sending
        if assets == nil {
            var inputData = [UInt8]()
            inputData.append(0)
            return (0, Data(bytes: inputData), nil)
        }

        var sortedUnspents = [UTXO]()
        var neededForTransaction = [UTXO]()
        if asset == .neoAssetId {
            sortedUnspents = assets!.getSortedNEOUTXOs()
            if sortedUnspents.reduce(0, {$0 + $1.value}) < Decimal(amount) {
                return (nil, nil, NSError())
            }
        } else {
            sortedUnspents = assets!.getSortedGASUTXOs()
            if sortedUnspents.reduce(0, {$0 + $1.value}) < Decimal(amount) {
                return (nil, nil, NSError())
            }
        }
        var runningAmount: Decimal = 0.0
        var index = 0
        var count: UInt8 = 0
        //Assume we always have enough balance to do this, prevent the check for bal
        while runningAmount < Decimal(amount) {
            neededForTransaction.append(sortedUnspents[index])
            runningAmount += sortedUnspents[index].value
            index += 1
            count += 1
        }
        var inputData = [UInt8]()
        inputData.append(count)
        for x in 0..<neededForTransaction.count {
            let data = neededForTransaction[x].txid.dataWithHexString()
            let reversedBytes = data.bytes.reversed()
            inputData += reversedBytes + toByteArray(UInt16(neededForTransaction[x].index))
        }

        return (runningAmount, Data(bytes: inputData), nil)
    }

    func packRawTransactionBytes(payloadPrefix: [UInt8], asset: AssetId, with inputData: Data, runningAmount: Decimal,
                                 toSendAmount: Double, toAddress: String, attributes: [TransactionAttritbute]? = nil) -> Data {
        let inputDataBytes = inputData.bytes
        let needsTwoOutputTransactions = runningAmount != Decimal(toSendAmount)

        var numberOfAttributes: UInt8 = 0x00
        var attributesPayload: [UInt8] = []
        if attributes != nil {
            for attribute in attributes! where attribute.data != nil {
                attributesPayload += attribute.data!
                numberOfAttributes += 1
            }
        }

        var payload: [UInt8] = payloadPrefix +  [numberOfAttributes]

        payload += attributesPayload + inputDataBytes

        //if it's the asset less sending
        if runningAmount == Decimal(0) {
            payload += [0x00]
            return Data(bytes: payload)
        }

        if needsTwoOutputTransactions {
            //Transaction To Reciever
            payload += [0x02] + asset.rawValue.dataWithHexString().bytes.reversed()
            let amountToSend = toSendAmount * pow(10, 8)
            let amountToSendRounded = round(amountToSend)
            let amountToSendInMemory = UInt64(amountToSendRounded)
            payload += toByteArray(amountToSendInMemory)

            //reciever addressHash
            payload += toAddress.hashFromAddress().dataWithHexString()

            //Transaction To Sender
            payload += asset.rawValue.dataWithHexString().bytes.reversed()
            let runningAmountRounded = round(NSDecimalNumber(decimal: runningAmount * pow(10, 8)).doubleValue)
            let amountToGetBack = runningAmountRounded - amountToSendRounded
            let amountToGetBackInMemory = UInt64(amountToGetBack)

            payload += toByteArray(amountToGetBackInMemory)
            payload += hashedSignature.bytes

        } else {
            payload += [0x01] + asset.rawValue.dataWithHexString().bytes.reversed()
            let amountToSend = toSendAmount * pow(10, 8)
            let amountToSendRounded = round(amountToSend)
            let amountToSendInMemory = UInt64(amountToSendRounded)

            payload += toByteArray(amountToSendInMemory)
            payload += toAddress.hashFromAddress().dataWithHexString()
        }
        return Data(bytes: payload)
    }

    func concatenatePayloadData(txData: Data, signatureData: Data) -> Data {
        var payload = txData.bytes + [0x01]                        // signature number
        payload += [0x41]                                 // signature struct length
        payload += [0x40]                                 // signature data length
        payload += signatureData.bytes                    // signature
        payload += [0x23]                                 // contract data length
        payload += [0x21] + self.publicKey.bytes + [0xac] // NeoSigned publicKey
        return Data(bytes: payload)
    }

    func generateSendTransactionPayload(asset: AssetId, amount: Double, toAddress: String, assets: Assets, attributes: [TransactionAttritbute]? = nil) -> Data {
        var error: NSError?
        let inputData = getInputsNecessaryToSendAsset(asset: asset, amount: amount, assets: assets)
        let payloadPrefix: [UInt8] = [0x80, 0x00]
        let rawTransaction = packRawTransactionBytes(payloadPrefix: payloadPrefix,
                                                     asset: asset, with: inputData.payload!, runningAmount: inputData.totalAmount!,
                                                     toSendAmount: amount, toAddress: toAddress, attributes: attributes)
        let signatureData = NeoutilsSign(rawTransaction, privateKey.fullHexString, &error)
        let finalPayload = concatenatePayloadData(txData: rawTransaction, signatureData: signatureData!)
        return finalPayload

    }

    public func sendAssetTransaction(network: Network, seedURL: String, asset: AssetId, amount: Double, toAddress: String, attributes: [TransactionAttritbute]? = nil, completion: @escaping(Bool?, Error?) -> Void) {
        O3APIClient(network: network).getUTXO(for: self.address, params: []) { result in
            switch result {
            case .failure(let error):
                completion(nil, error)
            case .success(let assets):
                let payload = self.generateSendTransactionPayload(asset: asset, amount: amount, toAddress: toAddress, assets: assets, attributes: attributes)
                NeoClient(seed: seedURL).sendRawTransaction(with: payload) { (result) in
                    switch result {
                    case .failure(let error):
                        completion(nil, error)
                    case .success(let response):
                        completion(response, nil)
                    }
                }
            }
        }
    }

    func generateClaimInputData(claims: Claimable) -> Data {
        var payload: [UInt8] = [0x02] // Claim Transaction Type
        payload += [0x00]    // Version
        //let claimsCount = UInt8(claims.claims.count)
        let claimsCount = UInt8(claims.claims.count)
        payload += [claimsCount]

        for claim in claims.claims {
            payload += claim.txid.dataWithHexString().bytes.reversed()
            payload += toByteArray(claim.index)
        }

        let amountDecimal = claims.gas * pow(10, 8)
        let amountInt = UInt64(round(NSDecimalNumber(decimal: amountDecimal).doubleValue))

        var attributes: [TransactionAttritbute] = []
        let remark = String(format: "O3XCLAIM")
        attributes.append(TransactionAttritbute(remark: remark))

        var numberOfAttributes: UInt8 = 0x00
        var attributesPayload: [UInt8] = []

        for attribute in attributes where attribute.data != nil {
            attributesPayload += attribute.data!
            numberOfAttributes += 1
        }

        payload += [numberOfAttributes]
        payload += attributesPayload
        payload += [0x00] // Inputs
        payload += [0x01] // Output Count
        payload += AssetId.gasAssetId.rawValue.dataWithHexString().bytes.reversed()
        payload += toByteArray(amountInt)
        payload += hashedSignature.bytes
        #if DEBUG
        print(payload.fullHexString)
        #endif
        return Data(bytes: payload)
    }

    func generateClaimTransactionPayload(claims: Claimable) -> Data {
        var error: NSError?
        let rawClaim = generateClaimInputData(claims: claims)
        let signatureData = NeoutilsSign(rawClaim, privateKey.fullHexString, &error)
        let finalPayload = concatenatePayloadData(txData: rawClaim, signatureData: signatureData!)
        return finalPayload
    }

    public func claimGas(network: Network, seedURL: String, completion: @escaping(Bool?, Error?) -> Void) {
        O3APIClient(network: network).getClaims(address: self.address) { result in
            switch result {
            case .failure(let error):
                completion(nil, error)
            case .success(let claims):
                let claimData = self.generateClaimTransactionPayload(claims: claims)
                print(claimData.fullHexString)
                NeoClient(seed: seedURL).sendRawTransaction(with: claimData) { (result) in
                    switch result {
                    case .failure(let error):
                        completion(nil, error)
                    case .success(let response):
                        completion(response, nil)
                    }
                }
            }
        }
    }

    private func generateInvokeTransactionPayload(assets: Assets?, script: String, contractAddress: String, attributes: [TransactionAttritbute]?) -> Data {
        var error: NSError?

        let inputData = getInputsNecessaryToSendAsset(asset: AssetId.gasAssetId, amount: 0.00000001, assets: assets)

        let payloadPrefix = [0xd1, 0x00] + script.dataWithHexString().bytes
        let rawTransaction = packRawTransactionBytes(payloadPrefix: payloadPrefix,
                                                     asset: AssetId.gasAssetId, with: inputData.payload!,
                                                     runningAmount: inputData.totalAmount!,
                                                     toSendAmount: 0.00000001, toAddress: self.address, attributes: attributes)
        let signatureData = NeoutilsSign(rawTransaction, privateKey.fullHexString, &error)
        let finalPayload = concatenatePayloadData(txData: rawTransaction, signatureData: signatureData!)
        return finalPayload
    }

    private func buildNEP5TransferScript(scriptHash: String, fromAddress: String,
                                         toAddress: String, amount: Double) -> [UInt8] {
        let amountToSendInMemory = Int(amount * 100000000)
        let fromAddressHash = fromAddress.hashFromAddress()
        let toAddressHash = toAddress.hashFromAddress()
        let scriptBuilder = ScriptBuilder()
        scriptBuilder.pushContractInvoke(scriptHash: scriptHash, operation: "transfer",
                                         args: [amountToSendInMemory, toAddressHash, fromAddressHash])
        let script = scriptBuilder.rawBytes
        return [UInt8(script.count)] + script
    }

    public func sendNep5Token(seedURL: String, tokenContractHash: String, amount: Double, toAddress: String, attributes: [TransactionAttritbute]? = nil, completion: @escaping(Bool?, Error?) -> Void) {

        var customAttributes: [TransactionAttritbute] = []
        customAttributes.append(TransactionAttritbute(script: self.address.hashFromAddress()))
        let remark = String(format: "O3X%@", Date().timeIntervalSince1970.description)
        customAttributes.append(TransactionAttritbute(remark: remark))
        customAttributes.append(TransactionAttritbute(descriptionHex: tokenContractHash))

        //send nep5 token without using utxo
        let scriptBytes = self.buildNEP5TransferScript(scriptHash: tokenContractHash,
                                                       fromAddress: self.address, toAddress: toAddress, amount: amount)
        var payload = self.generateInvokeTransactionPayload(assets: nil, script: scriptBytes.fullHexString,
                                                            contractAddress: tokenContractHash, attributes: customAttributes )
        payload += tokenContractHash.dataWithHexString().bytes
        print(payload.fullHexString)
        NeoClient(seed: seedURL).sendRawTransaction(with: payload) { (result) in
            switch result {
            case .failure(let error):
                completion(nil, error)
            case .success(let response):
                completion(response, nil)
            }
        }
    }

    public func allowToParticipateInTokenSale(seedURL: String, scriptHash: String, completion: @escaping(NeoClientResult<Bool>) -> Void) {
        NeoClient(seed: seedURL).getTokenSaleStatus(for: self.address, scriptHash: scriptHash) { result in
            completion(result)
        }
    }

    public func participateTokenSales(network: Network, seedURL: String, scriptHash: String, assetID: String, amount: Float64, remark: String, networkFee: Float64, completion: @escaping(Bool?, String, Error?) -> Void) {

        var networkString = "main"
        if network == .test {
            networkString = "test"
        }
        var error: NSError?

        let payload = NeoutilsMintTokensRawTransactionMobile(networkString, scriptHash, self.wif, assetID, amount, remark, networkFee, &error)
        if payload == nil {
            completion(false, "", error)
            return
        }
        NeoClient(seed: seedURL).sendRawTransaction(with: payload!.data()) { (result) in
            switch result {
            case .failure(let error):
                completion(nil, "", error)
            case .success(let response):
                completion(response, payload!.txid(), nil)
            }
        }
    }
}
