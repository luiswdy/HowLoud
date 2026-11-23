//
//  HowLoudUITests.swift
//  HowLoudUITests
//
//  Created by Luis Wu on 4/29/16.
//  Copyright © 2016 Luis Wu. All rights reserved.
//

import XCTest

class HowLoudUITests: XCTestCase {
        
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIApplication().launch()
    }
    
    func testAppLaunchesWithUIElements() {
        let app = XCUIApplication()
        XCTAssertTrue(app.staticTexts["HowLoud"].exists)
        XCTAssertTrue(app.buttons["toggleButton"].exists)
        XCTAssertTrue(app.buttons["calibrationButton"].exists)
        
        app.buttons["calibrationButton"].tap()
        XCTAssertTrue(app.navigationBars["Calibration"].waitForExistence(timeout: 3.0))
        app.buttons["calibrationDoneButton"].tap()
    }
}
