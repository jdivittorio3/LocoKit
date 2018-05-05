//
//  TimelineRecorder.swift
//  LocoKit
//
//  Created by Matt Greenfield on 29/04/18.
//

import LocoKitCore

public extension NSNotification.Name {
    public static let newTimelineItem = Notification.Name("newTimelineItem")
    public static let updatedTimelineItem = Notification.Name("updatedTimelineItem")
}

public class TimelineRecorder {

    // MARK: - Settings

    /**
     The maximum number of samples to record per minute.

     - Note: The actual number of samples recorded per minute may be less than this, depending on data availability.
     */
    public var samplesPerMinute: Double = 10

    // MARK: - Recorder creation

    private(set) public var store: TimelineStore
    private(set) public var classifier: MLCompositeClassifier?

    // convenience access to an often used optional bool
    public var canClassify: Bool { return classifier?.canClassify == true }

    public init(store: TimelineStore, classifier: MLCompositeClassifier? = nil) {
        self.store = store
        self.classifier = classifier

        // bootstrap the current item
        self.currentItem = store.mostRecentItem

        let notes = NotificationCenter.default
        notes.addObserver(forName: .locomotionSampleUpdated, object: nil, queue: nil) { [weak self] _ in
            self?.recordSample()
        }
        notes.addObserver(forName: .willStartSleepMode, object: nil, queue: nil) { [weak self] _ in
            if let currentItem = self?.currentItem {
                TimelineProcessor.process(from: currentItem)
            }
            self?.recordSample()
        }
        notes.addObserver(forName: .recordingStateChanged, object: nil, queue: nil) { [weak self] _ in
            self?.updateSleepModeAcceptability()
        }
    }

    // MARK: - Starting and stopping recording

    public func startRecording() {
        if isRecording { return }
        addDataGapItem()
        LocomotionManager.highlander.startRecording()
    }

    public func stopRecording() {
        LocomotionManager.highlander.stopRecording()
    }

    public var isRecording: Bool {
        return LocomotionManager.highlander.recordingState != .off
    }

    // MARK: - Startup

    private func addDataGapItem() {
        store.process {
            guard let lastItem = self.currentItem, let lastEndDate = lastItem.endDate else { return }

            // don't add a data gap after a data gap
            if lastItem.isDataGap { return }

            // is the gap too short to be worth filling?
            if lastEndDate.age < LocomotionManager.highlander.sleepCycleDuration { return }

            // the edge samples
            let startSample = PersistentSample(date: lastEndDate, recordingState: .off, in: self.store)
            let endSample = PersistentSample(date: Date(), recordingState: .off, in: self.store)

            // the gap item
            let gapItem = self.store.createPath(from: startSample)
            gapItem.previousItem = lastItem
            gapItem.add(endSample)

            // make it current
            self.currentItem = gapItem
        }
    }

    // MARK: - The recording cycle

    private(set) public var currentItem: TimelineItem?

    public var currentVisit: Visit? { return currentItem as? Visit }

    private var lastRecorded: Date?
    
    private func recordSample() {
        guard isRecording else { return }

        // don't record too soon
        if let lastRecorded = lastRecorded, lastRecorded.age < 60.0 / samplesPerMinute { return }

        lastRecorded = Date()

        let sample = store.createSample(from: ActivityBrain.highlander.presentSample)

        // classify the sample, if a classifier has been provided
        sample.classifierResults = classifier?.classify(sample, filtered: true)
        sample.unfilteredClassifierResults = classifier?.classify(sample, filtered: false)

        // make sure sleep mode doesn't happen prematurely
        updateSleepModeAcceptability()

        store.process {
            self.process(sample)
            self.updateSleepModeAcceptability()
        }
    }

    private func process(_ sample: LocomotionSample) {
        let loco = LocomotionManager.highlander

        /** first timeline item **/
        guard let currentItem = currentItem else {
            createTimelineItem(from: sample)
            return
        }

        /** datagap -> anything **/
        if currentItem.isDataGap {
            createTimelineItem(from: sample)
            return
        }

        let previouslyMoving = currentItem is Path
        let currentlyMoving = sample.movingState != .stationary

        /** stationary -> moving || moving -> stationary **/
        if currentlyMoving != previouslyMoving {
            createTimelineItem(from: sample)
            return
        }

        /** moving -> moving **/
        if previouslyMoving && currentlyMoving {

            // if activityType hasn't changed, reuse current
            if sample.activityType == currentItem.movingActivityType {
                currentItem.add(sample)
                return
            }

            // if edge speeds are above the mode change threshold, reuse current
            if let currentSpeed = currentItem.samples.last?.location?.speed, let sampleSpeed = sample.location?.speed {
                if currentSpeed > Path.maximumModeShiftSpeed && sampleSpeed > Path.maximumModeShiftSpeed {
                    currentItem.add(sample)
                    return
                }
            }

            // couldn't reuse current path
            createTimelineItem(from: sample)
            return
        }

        /** stationary -> stationary **/

        // if in sleep mode, only retain the last 10 sleep mode samples
        if loco.recordingState != .recording {
            let sleepSamples = currentItem.samples.suffix(10).filter { $0.recordingState != .recording }
            if sleepSamples.count == 10, let oldestSleep = sleepSamples.first {
                currentItem.remove(oldestSleep)
            }
        }

        currentItem.add(sample)
    }

    private func updateSleepModeAcceptability() {
        let loco = LocomotionManager.highlander
        if let currentVisit = currentItem as? Visit, currentVisit.isWorthKeeping {
            loco.useLowPowerSleepModeWhileStationary = true

        } else {
            loco.useLowPowerSleepModeWhileStationary = false
            // not recording, but should be?
            if loco.recordingState != .recording { loco.startRecording() }
        }
    }

    // MARK: - Timeline item creation

    private func createTimelineItem(from sample: LocomotionSample) {
        let newItem: TimelineItem = sample.movingState == .stationary
            ? store.createVisit(from: sample)
            : store.createPath(from: sample)

        // keep the list linked
        newItem.previousItem = currentItem

        // new item becomes current
        currentItem = newItem

        onMain {
            let note = Notification(name: .newTimelineItem, object: self, userInfo: ["timelineItem": newItem])
            NotificationCenter.default.post(note)
        }
    }

}