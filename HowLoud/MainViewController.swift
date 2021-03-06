//
//  ViewController.swift
//  HowLoud
//
//  Created by Luis Wu on 4/29/16.
//  Copyright © 2016 Luis Wu. All rights reserved.
//

import UIKit
import SGauge

class MainViewController: UIViewController {
    private var presenter = MainPresenter()
    
    @IBOutlet weak var toggleButton: UIButton!
    @IBOutlet weak var avgSplLabel: UILabel!
    @IBOutlet weak var peakSplLabel: UILabel!
    @IBOutlet weak var minValueLabel: UILabel!
    @IBOutlet weak var maxValueLabel: UILabel!
    @IBOutlet weak var gauge: SGauge!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        /* As the decibel meter in the presenter constantly emits data,
           thus I added a callback so that the view controller
           can get data for its presentation
         */
        self.presenter.subscribeDecibelInfo { [unowned self] (avgSpl, avgInfo, peakInfo) in
            self.gauge.value = avgSpl
            self.avgSplLabel.text = avgInfo
            self.peakSplLabel.text = peakInfo
        }
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
        // check if the app has permission accessing the microphone
        checkMicPermission()
    }
    
    private func setupUI() {
        gauge.maxValue = CGFloat(DecibelMeter.MaxValue)
        gauge.minValue = CGFloat(DecibelMeter.MinValue)
        minValueLabel.text = presenter.decibelMeterMinValue
        maxValueLabel.text = presenter.decibelMeterMaxValue
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    @IBAction func toggleMeasuring(sender: UIButton) {
        sender.selected = presenter.toggleMeasuring()
    }
    
    private func checkMicPermission() {
        if !presenter.allowMic(){
            let appName = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleName") as! String
            let micAlertViewController = UIAlertController.init(title: NSLocalizedString("mic_perm_req", comment: ""),
                                   message: String(format: NSLocalizedString("mic_perm_description", comment: ""), appName),
                                   preferredStyle: .Alert)
            micAlertViewController.addAction(UIAlertAction(title: NSLocalizedString("got_it", comment: ""), style: .Default, handler: nil))
            self.presentViewController(micAlertViewController, animated: true, completion: nil)
        }
    }
}

