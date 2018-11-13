//
//  UnlockMultiWalletTableViewController.swift
//  O3
//
//  Created by Andrei Terentiev on 11/5/18.
//  Copyright © 2018 O3 Labs Inc. All rights reserved.
//

import Foundation
import UIKit
import SwiftTheme
import Neoutils

class UnlockMultiWalletTableViewController: UITableViewController {
    let nep6 = NEP6.getFromFileSystem()!
    
    var accounts = [NEP6.Account]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setThemedElements()
    }
    
    func setThemedElements() {
        tableView.theme_backgroundColor = O3Theme.backgroundColorPicker
        view.theme_backgroundColor = O3Theme.backgroundColorPicker
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "unlockWalletTableViewCell") as? UnlockMultiWalletTableViewCell else {
            fatalError("Invalid cell")
        }
        (cell.viewWithTag(2) as! UILabel).text = accounts[indexPath.row].label
        return cell
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        var accountsToDisplay = [NEP6.Account]()
        for account in nep6.accounts {
            if account.isDefault == false && account.key != nil {
                accountsToDisplay.append(account)
            }
        }
        accounts = accountsToDisplay
        return accountsToDisplay.count
    }
    
    func displayPasswordInput(key: String) {
        let alertController = UIAlertController(title: "Enter the password", message: "It will replace default ", preferredStyle: .alert)
        let confirmAction = UIAlertAction(title: OzoneAlert.okPositiveConfirmString, style: .default) { (_) in
            let inputPass = alertController.textFields?[0].text!
            var error: NSError?
            let _ = NeoutilsNEP2Decrypt(key, inputPass, &error)
            self.navigationController?.popViewController(animated: true)
            if error == nil {
                NEP6.makeNewDefault(key: key, pass: inputPass!)
                self.dismiss(animated: true)
            } else {
                OzoneAlert.alertDialog(message: "Error", dismissTitle: "Ok") {}
            }
        }
        
        let cancelAction = UIAlertAction(title: OzoneAlert.cancelNegativeConfirmString, style: .cancel) { (_) in }
        
        alertController.addTextField { (textField) in
            textField.placeholder = "Password"
            textField.isSecureTextEntry = true
        }
        
        alertController.addAction(confirmAction)
        alertController.addAction(cancelAction)
        
        UIApplication.shared.keyWindow?.rootViewController?.presentFromEmbedded(alertController, animated: true, completion: nil)
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = accounts[indexPath.row].key!
        displayPasswordInput(key: key)
    }
}