/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    The application delegate.
*/

import UIKit
import ListerKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UISplitViewControllerDelegate {
    // MARK: Types
    
    struct MainStoryboard {
        static let name = "Main"
        
        struct Identifiers {
            static let emptyViewController = "emptyViewController"
        }
    }
    
    enum ShortcutIdentifier: String {
        case NewInToday
        
        // MARK: Initializers
        
        init?(fullType: String) {
            guard let last = fullType.components(separatedBy: ".").last else { return nil }
            
            self.init(rawValue: last)
        }
        
        // MARK: Properties
        
        var type: String {
            return Bundle.main.bundleIdentifier! + ".\(self.rawValue)"
        }
    }

    // MARK: Properties

    var window: UIWindow?

    var listsController: ListsController!
    
    var launchedShortcutItem: UIApplicationShortcutItem?
    
    /**
        A private, local queue used to ensure serialized access to Cloud containers during application
        startup.
    */
    let appDelegateQueue = DispatchQueue(label: "com.example.apple-samplecode.lister.appdelegate", attributes: [])

    // MARK: View Controller Accessor Convenience
    
    /**
        The root view controller of the window will always be a `UISplitViewController`. This is set up
        in the main storyboard.
    */
    var splitViewController: UISplitViewController {
        return window!.rootViewController as! UISplitViewController
    }

    /// The primary view controller of the split view controller defined in the main storyboard.
    var primaryViewController: UINavigationController {
        return splitViewController.viewControllers.first as! UINavigationController
    }
    
    /**
        The view controller that displays the list of documents. If it's not visible, then this value
        is `nil`.
    */
    var listDocumentsViewController: ListDocumentsViewController? {
        return primaryViewController.viewControllers.first as? ListDocumentsViewController
    }
    
    // MARK: UIApplicationDelegate
    
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        let appConfiguration = AppConfiguration.sharedConfiguration
        if appConfiguration.isCloudAvailable {
            /*
                Ensure the app sandbox is extended to include the default container. Perform this action on the
                `AppDelegate`'s serial queue so that actions dependent on the extension always follow it.
            */
            appDelegateQueue.async {
                // The initial call extends the sandbox. No need to capture the URL.
                FileManager.default.url(forUbiquityContainerIdentifier: nil)
                
                return
            }
        }
        
        return true
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Observe changes to the user's iCloud account status (account changed, logged out, etc...).
        NotificationCenter.default.addObserver(self, selector: #selector(AppDelegate.handleUbiquityIdentityDidChangeNotification(_:)), name: NSNotification.Name.NSUbiquityIdentityDidChange, object: nil)
        
        // Provide default lists from the app's bundle on first launch.
        AppConfiguration.sharedConfiguration.runHandlerOnFirstLaunch {
            ListUtilities.copyInitialLists()
        }

        splitViewController.delegate = self
        splitViewController.preferredDisplayMode = .allVisible
        
        // Configure the detail controller in the `UISplitViewController` at the root of the view hierarchy.
        let navigationController = splitViewController.viewControllers.last as! UINavigationController
        navigationController.topViewController?.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem
        navigationController.topViewController?.navigationItem.leftItemsSupplementBackButton = true
        
        var shouldPerformAdditionalDelegateHandling = true
        
        // If a shortcut was launched, display its information and take the appropriate action.
        if let shortcutItem = launchOptions?[UIApplicationLaunchOptionsKey.shortcutItem] as? UIApplicationShortcutItem {
            
            launchedShortcutItem = shortcutItem
            
            // This will block "performActionForShortcutItem:completionHandler" from being called.
            shouldPerformAdditionalDelegateHandling = false
        }
        
        // Make sure that user storage preferences are set up after the app sandbox is extended. See `application(_:, willFinishLaunchingWithOptions:)` above.
        appDelegateQueue.async {
            self.setupUserStoragePreferences()
        }
        
        return shouldPerformAdditionalDelegateHandling
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard let launchedShortcutItem = launchedShortcutItem else { return }
        
        // Make sure that shortcut handling occurs after storage preference have been set. See `application(_:, didFinishLaunchingWithOptions:)` above.
        appDelegateQueue.async {
            self.handleApplicationShortcutItem(launchedShortcutItem)
            self.launchedShortcutItem = nil
        }
    }
    
    func application(_: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]?) -> Void) -> Bool {
        // Lister only supports a single user activity type; if you support more than one the type is available from the `continueUserActivity` parameter.
        if let listDocumentsViewController = listDocumentsViewController {
            // Make sure that user activity continuation occurs after the app sandbox is extended. See `application(_:, willFinishLaunchingWithOptions:)` above.
            appDelegateQueue.async {
                restorationHandler([listDocumentsViewController])
            }
            
            return true
        }
        
        return false
    }
    
    func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        // Lister currently only opens URLs of the Lister scheme type.
        if url.scheme == AppConfiguration.ListerScheme.name {
            // Obtain an app launch context from the provided lister:// URL and configure the view controller with it.
            guard let launchContext = AppLaunchContext(listerURL: url) else { return false }
            
            if let listDocumentsViewController = listDocumentsViewController {
                // Make sure that URL opening is handled after the app sandbox is extended. See `application(_:, willFinishLaunchingWithOptions:)` above.
                appDelegateQueue.async {
                    listDocumentsViewController.configureViewControllerWithLaunchContext(launchContext)
                }
                
                return true
            }
        }
        
        return false
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        // Make sure that shortcut handling is coordinated with other activities handled asynchronously.
        appDelegateQueue.async {
            completionHandler(self.handleApplicationShortcutItem(shortcutItem))
        }
    }
    
    // MARK: UISplitViewControllerDelegate

    func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController: UIViewController, onto _: UIViewController) -> Bool {
        /*
            In a regular width size class, Lister displays a split view controller with a navigation controller
            displayed in both the master and detail areas.
            If there's a list that's currently selected, it should be on top of the stack when collapsed. 
            Ensuring that the navigation bar takes on the appearance of the selected list requires the 
            transfer of the configuration of the navigation controller that was shown in the detail area.
        */
        if secondaryViewController is UINavigationController && (secondaryViewController as! UINavigationController).topViewController is ListViewController {
            // Obtain a reference to the navigation controller currently displayed in the detail area.
            let secondaryNavigationController = secondaryViewController as! UINavigationController
            
            // Transfer the settings for the `navigationBar` and the `toolbar` to the main navigation controller.
            primaryViewController.navigationBar.titleTextAttributes = secondaryNavigationController.navigationBar.titleTextAttributes
            primaryViewController.navigationBar.tintColor = secondaryNavigationController.navigationBar.tintColor
            primaryViewController.toolbar?.tintColor = secondaryNavigationController.toolbar?.tintColor
            
            return false
        }
        
        return true
    }
    
    func splitViewController(_ splitViewController: UISplitViewController, separateSecondaryFrom _: UIViewController) -> UIViewController? {
        /*
            In this delegate method, the reverse of the collapsing procedure described above needs to be
            carried out if a list is being displayed. The appropriate controller to display in the detail area
            should be returned. If not, the standard behavior is obtained by returning nil.
        */
        if primaryViewController.topViewController is UINavigationController && (primaryViewController.topViewController as! UINavigationController).topViewController is ListViewController {
            // Obtain a reference to the navigation controller containing the list controller to be separated.
            let secondaryViewController = primaryViewController.popViewController(animated: false) as! UINavigationController
            let listViewController = secondaryViewController.topViewController as! ListViewController
            
            // Obtain the `textAttributes` and `tintColor` to setup the separated navigation controller.    
            let textAttributes = listViewController.textAttributes
            let tintColor = listViewController.listPresenter.color.colorValue
            
            // Transfer the settings for the `navigationBar` and the `toolbar` to the detail navigation controller.
            secondaryViewController.navigationBar.titleTextAttributes = textAttributes
            secondaryViewController.navigationBar.tintColor = tintColor
            secondaryViewController.toolbar?.tintColor = tintColor
            
            // Display a bar button on the left to allow the user to expand or collapse the main area, similar to Mail.
            secondaryViewController.topViewController?.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem
            
            return secondaryViewController
        }
        
        return nil
    }
    
    // MARK: Notifications
    
    func handleUbiquityIdentityDidChangeNotification(_ notification: Notification) {
        primaryViewController.popToRootViewController(animated: true)
        
        setupUserStoragePreferences()
    }
    
    // MARK: User Storage Preferences
    
    func setupUserStoragePreferences() {
        let storageState = AppConfiguration.sharedConfiguration.storageState
    
        /*
            Check to see if the account has changed since the last time the method was called. If it has, let
            the user know that their documents have changed. If they've already chosen local storage (i.e. not
            iCloud), don't notify them since there's no impact.
        */
        if storageState.accountDidChange && storageState.storageOption == .cloud {
            notifyUserOfAccountChange(storageState)
            // Return early. State resolution will take place after the user acknowledges the change.
            return
        }

        resolveStateForUserStorageState(storageState)
    }
    
    func resolveStateForUserStorageState(_ storageState: StorageState) {
        if storageState.cloudAvailable {
            if storageState.storageOption == .notSet  || (storageState.storageOption == .local && storageState.accountDidChange) {
                // iCloud is available, but we need to ask the user what they prefer.
                promptUserForStorageOption()
            }
            else {
                /*
                    The user has already selected a specific storage option. Set up the lists controller to use
                    that storage option.
                */
                configureListsController(accountChanged: storageState.accountDidChange)
            }
        }
        else {
            /* 
                iCloud is not available, so we'll reset the storage option and configure the list controller.
                The next time that the user signs in with an iCloud account, he or she can change provide their
                desired storage option.
            */
            if storageState.storageOption != .notSet {
                AppConfiguration.sharedConfiguration.storageOption = .notSet
            }
            
            configureListsController(accountChanged: storageState.accountDidChange)
        }
    }
    
    // MARK: Alerts
    
    func notifyUserOfAccountChange(_ storageState: StorageState) {
        /*
            Copy a 'Today' list from the bundle to the local documents directory if a 'Today' list doesn't exist.
            This provides more context for the user than no lists and ensures the user always has a 'Today' list (a
            design choice made in Lister).
        */
        if !storageState.cloudAvailable {
            ListUtilities.copyTodayList()
        }
        
        let title = NSLocalizedString("Sign Out of iCloud", comment: "")
        let message = NSLocalizedString("You have signed out of the iCloud account previously used to store documents. Sign back in with that account to access those documents.", comment: "")
        let okActionTitle = NSLocalizedString("OK", comment: "")
        
        let signedOutController = UIAlertController(title: title, message: message, preferredStyle: .alert)

        let action = UIAlertAction(title: okActionTitle, style: .cancel) { _ in
            self.resolveStateForUserStorageState(storageState)
        }
        signedOutController.addAction(action)
        
        DispatchQueue.main.async {
            self.listDocumentsViewController?.present(signedOutController, animated: true, completion: nil)
        }
    }
    
    func promptUserForStorageOption() {
        let title = NSLocalizedString("Choose Storage Option", comment: "")
        let message = NSLocalizedString("Do you want to store documents in iCloud or only on this device?", comment: "")
        let localOnlyActionTitle = NSLocalizedString("Local Only", comment: "")
        let cloudActionTitle = NSLocalizedString("iCloud", comment: "")
        
        let storageController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        let localOption = UIAlertAction(title: localOnlyActionTitle, style: .default) { localAction in
            AppConfiguration.sharedConfiguration.storageOption = .local

            self.configureListsController(accountChanged: true)
        }
        storageController.addAction(localOption)
        
        let cloudOption = UIAlertAction(title: cloudActionTitle, style: .default) { cloudAction in
            AppConfiguration.sharedConfiguration.storageOption = .cloud

            self.configureListsController(accountChanged: true) {
                ListUtilities.migrateLocalListsToCloud()
            }
        }
        storageController.addAction(cloudOption)
        
        DispatchQueue.main.async {
            self.listDocumentsViewController?.present(storageController, animated: true, completion: nil)
        }
    }
   
    // MARK: Convenience
    
    func handleApplicationShortcutItem(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        // Verify that the provided `shortcutItem`'s `type` is one handled by the application.
        guard let shortcutIdentifier = ShortcutIdentifier(fullType: shortcutItem.type) else { return false }
        
        switch shortcutIdentifier {
            case .NewInToday:
                guard let listDocuments = self.listDocumentsViewController else { return false }
                guard let listsController = self.listsController else { return false }
                
                let todayURL = listsController.documentsDirectory.appendingPathComponent(AppConfiguration.localizedTodayDocumentNameAndExtension, isDirectory: false)
                let launchContext = AppLaunchContext(listURL: todayURL, listColor: List.Color.orange)
                
                listDocuments.configureViewControllerWithLaunchContext(launchContext)
                
                return true
        }
        
        // The switch is exhaustive so there is no need for a 'final' return statement.
    }
    
    func configureListsController(accountChanged: Bool, storageOptionChangeHandler: ((Void) -> Void)? = nil) {
        if listsController != nil && !accountChanged {
            // The current controller is correct. There is no need to reconfigure it.
            return
        }

        if listsController == nil {
            // There is currently no lists controller. Configure an appropriate one for the current configuration.
            listsController = AppConfiguration.sharedConfiguration.listsControllerForCurrentConfigurationWithPathExtension(AppConfiguration.listerFileExtension, firstQueryHandler: storageOptionChangeHandler)
            
            // Ensure that this controller is passed along to the `ListDocumentsViewController`.
            listDocumentsViewController?.listsController = listsController
            
            listsController.startSearching()
        }
        else if accountChanged {
            // A lists controller is configured; however, it needs to have its coordinator updated based on the account change. 
            listsController.listCoordinator = AppConfiguration.sharedConfiguration.listCoordinatorForCurrentConfigurationWithPathExtension(AppConfiguration.listerFileExtension, firstQueryHandler: storageOptionChangeHandler)
        }
    }
}

