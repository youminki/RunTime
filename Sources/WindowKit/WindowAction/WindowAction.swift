/// WindowAction.swift

import Foundation
import Carbon
import Cocoa

fileprivate let alt = NSEvent.ModifierFlags.option.rawValue
fileprivate let ctrl = NSEvent.ModifierFlags.control.rawValue
fileprivate let shift = NSEvent.ModifierFlags.shift.rawValue
fileprivate let cmd = NSEvent.ModifierFlags.command.rawValue

enum WindowAction: Int, Codable {
    case leftHalf = 0,
         rightHalf = 1,
         maximize = 2,
         maximizeHeight = 3,
         previousDisplay = 4,
         nextDisplay = 5,
         larger = 8,
         smaller = 9,
         bottomHalf = 10,
         topHalf = 11,
         center = 12,
         bottomLeft = 13,
         bottomRight = 14,
         topLeft = 15,
         topRight = 16,
         restore = 19,
         firstThird = 20,
         firstTwoThirds = 21,
         centerThird = 22,
         lastTwoThirds = 23,
         lastThird = 24,
         moveLeft = 25,
         moveRight = 26,
         moveUp = 27,
         moveDown = 28,
         almostMaximize = 29,
         centerHalf = 30,
         firstFourth = 31,
         secondFourth = 32,
         thirdFourth = 33,
         lastFourth = 34,
         firstThreeFourths = 35,
         lastThreeFourths = 36,
         topLeftSixth = 37,
         topCenterSixth = 38,
         topRightSixth = 39,
         bottomLeftSixth = 40,
         bottomCenterSixth = 41,
         bottomRightSixth = 42,
         specified = 43,
         reverseAll = 44,
         topLeftNinth = 45,
         topCenterNinth = 46,
         topRightNinth = 47,
         middleLeftNinth = 48,
         middleCenterNinth = 49,
         middleRightNinth = 50,
         bottomLeftNinth = 51,
         bottomCenterNinth = 52,
         bottomRightNinth = 53,
         topLeftThird = 54,
         topRightThird = 55,
         bottomLeftThird = 56,
         bottomRightThird = 57,
         topLeftEighth = 58,
         topCenterLeftEighth = 59,
         topCenterRightEighth = 60,
         topRightEighth = 61,
         bottomLeftEighth = 62,
         bottomCenterLeftEighth = 63,
         bottomCenterRightEighth = 64,
         bottomRightEighth = 65,
         tileAll = 66,
         cascadeAll = 67,
         leftTodo = 68,
         rightTodo = 69,
         cascadeActiveApp = 70,
         centerProminently = 71,
         doubleHeightUp = 72,
         doubleHeightDown = 73,
         doubleWidthLeft = 74,
         doubleWidthRight = 75,
         halveHeightUp = 76,
         halveHeightDown = 77,
         halveWidthLeft = 78,
         halveWidthRight = 79,
         largerWidth = 80,
         smallerWidth = 81,
         largerHeight = 82,
         smallerHeight = 83,
         centerTwoThirds = 84,
         centerThreeFourths = 85,
         tileActiveApp = 86,
         topVerticalThird = 87,
         middleVerticalThird = 88,
         bottomVerticalThird = 89,
         topVerticalTwoThirds = 90,
         bottomVerticalTwoThirds = 91,
         topLeftTwelfth = 92,
         topCenterLeftTwelfth = 93,
         topCenterRightTwelfth = 94,
         topRightTwelfth = 95,
         middleLeftTwelfth = 96,
         middleCenterLeftTwelfth = 97,
         middleCenterRightTwelfth = 98,
         middleRightTwelfth = 99,
         bottomLeftTwelfth = 100,
         bottomCenterLeftTwelfth = 101,
         bottomCenterRightTwelfth = 102,
         bottomRightTwelfth = 103,
         topLeftSixteenth = 104,
         topCenterLeftSixteenth = 105,
         topCenterRightSixteenth = 106,
         topRightSixteenth = 107,
         upperMiddleLeftSixteenth = 108,
         upperMiddleCenterLeftSixteenth = 109,
         upperMiddleCenterRightSixteenth = 110,
         upperMiddleRightSixteenth = 111,
         lowerMiddleLeftSixteenth = 112,
         lowerMiddleCenterLeftSixteenth = 113,
         lowerMiddleCenterRightSixteenth = 114,
         lowerMiddleRightSixteenth = 115,
         bottomLeftSixteenth = 116,
         bottomCenterLeftSixteenth = 117,
         bottomCenterRightSixteenth = 118,
         bottomRightSixteenth = 119,
         displayOne = 120,
         displayTwo = 121,
         displayThree = 122,
         displayFour = 123,
         displayFive = 124,
         displaySix = 125,
         displaySeven = 126,
         displayEight = 127,
         displayNine = 128,
         tileRows = 129,
         tileColumns = 130,
         cycleStackedWindows = 131,
         cycleStackedWindowsBackward = 132,
         firstVerticalEighth = 133,
         secondVerticalEighth = 134,
         thirdVerticalEighth = 135,
         fourthVerticalEighth = 136,
         fifthVerticalEighth = 137,
         sixthVerticalEighth = 138,
         seventhVerticalEighth = 139,
         lastVerticalEighth = 140,
         firstVerticalSixth = 141,
         secondVerticalSixth = 142,
         thirdVerticalSixth = 143,
         fourthVerticalSixth = 144,
         fifthVerticalSixth = 145,
         lastVerticalSixth = 146

    // Order matters here - it's used in the menu
    static let active = [leftHalf, rightHalf, centerHalf, topHalf, bottomHalf,
                         topLeft, topRight, bottomLeft, bottomRight,
                         firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds,
                         topVerticalThird, middleVerticalThird, bottomVerticalThird, topVerticalTwoThirds, bottomVerticalTwoThirds,
                         maximize, almostMaximize, maximizeHeight, larger, smaller, largerWidth, smallerWidth, largerHeight, smallerHeight,
                         center, centerProminently, restore,
                         nextDisplay, previousDisplay,
                         moveLeft, moveRight, moveUp, moveDown,
                         firstFourth, secondFourth, thirdFourth, lastFourth, firstThreeFourths, centerThreeFourths, lastThreeFourths,
                         topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth,
                         specified, reverseAll,
                         topLeftThird, topRightThird, bottomLeftThird, bottomRightThird,
                         topLeftEighth, topCenterLeftEighth, topCenterRightEighth, topRightEighth,
                         bottomLeftEighth, bottomCenterLeftEighth, bottomCenterRightEighth, bottomRightEighth,
                         firstVerticalEighth, secondVerticalEighth, thirdVerticalEighth, fourthVerticalEighth,
                         fifthVerticalEighth, sixthVerticalEighth, seventhVerticalEighth, lastVerticalEighth,
                         firstVerticalSixth, secondVerticalSixth, thirdVerticalSixth,
                         fourthVerticalSixth, fifthVerticalSixth, lastVerticalSixth,
                         topLeftNinth, topCenterNinth, topRightNinth,
                         middleLeftNinth, middleCenterNinth, middleRightNinth,
                         bottomLeftNinth, bottomCenterNinth, bottomRightNinth,
                         topLeftTwelfth, topCenterLeftTwelfth, topCenterRightTwelfth, topRightTwelfth,
                         middleLeftTwelfth, middleCenterLeftTwelfth, middleCenterRightTwelfth, middleRightTwelfth,
                         bottomLeftTwelfth, bottomCenterLeftTwelfth, bottomCenterRightTwelfth, bottomRightTwelfth,
                         topLeftSixteenth, topCenterLeftSixteenth, topCenterRightSixteenth, topRightSixteenth,
                         upperMiddleLeftSixteenth, upperMiddleCenterLeftSixteenth, upperMiddleCenterRightSixteenth, upperMiddleRightSixteenth,
                         lowerMiddleLeftSixteenth, lowerMiddleCenterLeftSixteenth, lowerMiddleCenterRightSixteenth, lowerMiddleRightSixteenth,
                         bottomLeftSixteenth, bottomCenterLeftSixteenth, bottomCenterRightSixteenth, bottomRightSixteenth,
                         doubleHeightUp, doubleHeightDown, doubleWidthLeft, doubleWidthRight,
                         halveHeightUp, halveHeightDown, halveWidthLeft, halveWidthRight,
                         tileAll, tileRows, tileColumns, cascadeAll,
                         leftTodo, rightTodo,
                         cascadeActiveApp, tileActiveApp,
                         displayOne, displayTwo, displayThree, displayFour, displayFive,
                         displaySix, displaySeven, displayEight, displayNine,
                         cycleStackedWindows, cycleStackedWindowsBackward
    ]

    func post() {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self))
    }
    
    func postMenu() {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, source: .menuItem))
    }

    func postSnap(windowElement: AccessibilityElement?, windowId: CGWindowID?, screen: NSScreen,
                  completion: (() -> Void)? = nil, cancellation: (() -> Void)? = nil) {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, updateRestoreRect: false, screen: screen, windowElement: windowElement, windowId: windowId, source: .dragToSnap, completion: completion, cancellation: cancellation))
    }
    
    func postUrl() {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, source: .url))
    }
    
    func postTitleBar(windowElement: AccessibilityElement?, screen: NSScreen? = nil) {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, screen: screen, windowElement: windowElement, source: .titleBar))
    }

    // Determines where separators should be used in the menu
    var firstInGroup: Bool {
        switch self {
        case .leftHalf, .topLeft, .firstThird, .maximize, .almostMaximize, .nextDisplay, .moveLeft, .firstFourth, .topLeftSixth, .topLeftEighth, .topLeftNinth, .topLeftTwelfth, .topLeftSixteenth, .tileRows:
            return true
        default:
            return false
        }
    }
    
    var excludedFromMenu: Bool {
        switch self {
        case .smallerWidth, .largerWidth, .topVerticalThird, .middleVerticalThird, .bottomVerticalThird, .topVerticalTwoThirds, .bottomVerticalTwoThirds,
             .firstVerticalEighth, .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth,
             .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth, .lastVerticalEighth,
             .firstVerticalSixth, .secondVerticalSixth, .thirdVerticalSixth,
             .fourthVerticalSixth, .fifthVerticalSixth, .lastVerticalSixth,
             .cycleStackedWindows, .cycleStackedWindowsBackward: return true
        default: return false
        }
    }

    var name: String {
        switch self {
        case .leftHalf: return "leftHalf"
        case .rightHalf: return "rightHalf"
        case .maximize: return "maximize"
        case .maximizeHeight: return "maximizeHeight"
        case .previousDisplay: return "previousDisplay"
        case .nextDisplay: return "nextDisplay"
        case .larger: return "larger"
        case .smaller: return "smaller"
        case .bottomHalf: return "bottomHalf"
        case .topHalf: return "topHalf"
        case .center: return "center"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .restore: return "restore"
        case .firstThird: return "firstThird"
        case .firstTwoThirds: return "firstTwoThirds"
        case .centerThird: return "centerThird"
        case .centerTwoThirds: return "centerTwoThirds"
        case .lastTwoThirds: return "lastTwoThirds"
        case .lastThird: return "lastThird"
        case .moveLeft: return "moveLeft"
        case .moveRight: return "moveRight"
        case .moveUp: return "moveUp"
        case .moveDown: return "moveDown"
        case .almostMaximize: return "almostMaximize"
        case .centerHalf: return "centerHalf"
        case .firstFourth: return "firstFourth"
        case .secondFourth: return "secondFourth"
        case .thirdFourth: return "thirdFourth"
        case .lastFourth: return "lastFourth"
        case .firstThreeFourths: return "firstThreeFourths"
        case .centerThreeFourths: return "centerThreeFourths"
        case .lastThreeFourths: return "lastThreeFourths"
        case .topLeftSixth: return "topLeftSixth"
        case .topCenterSixth: return "topCenterSixth"
        case .topRightSixth: return "topRightSixth"
        case .bottomLeftSixth: return "bottomLeftSixth"
        case .bottomCenterSixth: return "bottomCenterSixth"
        case .bottomRightSixth: return "bottomRightSixth"
        case .specified: return "specified"
        case .reverseAll: return "reverseAll"
        case .topLeftNinth: return "topLeftNinth"
        case .topCenterNinth: return "topCenterNinth"
        case .topRightNinth: return "topRightNinth"
        case .middleLeftNinth: return "middleLeftNinth"
        case .middleCenterNinth: return "middleCenterNinth"
        case .middleRightNinth: return "middleRightNinth"
        case .bottomLeftNinth: return "bottomLeftNinth"
        case .bottomCenterNinth: return "bottomCenterNinth"
        case .bottomRightNinth: return "bottomRightNinth"
        case .topLeftThird: return "topLeftThird"
        case .topRightThird: return "topRightThird"
        case .bottomLeftThird: return "bottomLeftThird"
        case .bottomRightThird: return "bottomRightThird"
        case .topLeftEighth: return "topLeftEighth"
        case .topCenterLeftEighth: return "topCenterLeftEighth"
        case .topCenterRightEighth: return "topCenterRightEighth"
        case .topRightEighth: return "topRightEighth"
        case .bottomLeftEighth: return "bottomLeftEighth"
        case .bottomCenterLeftEighth: return "bottomCenterLeftEighth"
        case .bottomCenterRightEighth: return "bottomCenterRightEighth"
        case .bottomRightEighth: return "bottomRightEighth"
        case .firstVerticalEighth: return "firstVerticalEighth"
        case .secondVerticalEighth: return "secondVerticalEighth"
        case .thirdVerticalEighth: return "thirdVerticalEighth"
        case .fourthVerticalEighth: return "fourthVerticalEighth"
        case .fifthVerticalEighth: return "fifthVerticalEighth"
        case .sixthVerticalEighth: return "sixthVerticalEighth"
        case .seventhVerticalEighth: return "seventhVerticalEighth"
        case .lastVerticalEighth: return "lastVerticalEighth"
        case .firstVerticalSixth: return "firstVerticalSixth"
        case .secondVerticalSixth: return "secondVerticalSixth"
        case .thirdVerticalSixth: return "thirdVerticalSixth"
        case .fourthVerticalSixth: return "fourthVerticalSixth"
        case .fifthVerticalSixth: return "fifthVerticalSixth"
        case .lastVerticalSixth: return "lastVerticalSixth"
        case .doubleHeightUp: return "doubleHeightUp"
        case .doubleHeightDown: return "doubleHeightDown"
        case .doubleWidthLeft: return "doubleWidthLeft"
        case .doubleWidthRight: return "doubleWidthRight"
        case .halveHeightUp: return "halveHeightUp"
        case .halveHeightDown: return "halveHeightDown"
        case .halveWidthLeft: return "halveWidthLeft"
        case .halveWidthRight: return "halveWidthRight"
        case .tileAll: return "tileAll"
        case .tileRows: return "tileRows"
        case .tileColumns: return "tileColumns"
        case .cycleStackedWindows: return "cycleStackedWindows"
        case .cycleStackedWindowsBackward: return "cycleStackedWindowsBackward"
        case .cascadeAll: return "cascadeAll"
        case .leftTodo: return "leftTodo"
        case .rightTodo: return "rightTodo"
        case .cascadeActiveApp: return "cascadeActiveApp"
        case .tileActiveApp: return "tileActiveApp"
        case .centerProminently: return "centerProminently"
        case .largerWidth: return "largerWidth"
        case .smallerWidth: return "smallerWidth"
        case .largerHeight: return "largerHeight"
        case .smallerHeight: return "smallerHeight"
        case .topVerticalThird: return "topVerticalThird"
        case .middleVerticalThird: return "middleVerticalThird"
        case .bottomVerticalThird: return "bottomVerticalThird"
        case .topVerticalTwoThirds: return "topVerticalTwoThirds"
        case .bottomVerticalTwoThirds: return "bottomVerticalTwoThirds"
        case .topLeftTwelfth: return "topLeftTwelfth"
        case .topCenterLeftTwelfth: return "topCenterLeftTwelfth"
        case .topCenterRightTwelfth: return "topCenterRightTwelfth"
        case .topRightTwelfth: return "topRightTwelfth"
        case .middleLeftTwelfth: return "middleLeftTwelfth"
        case .middleCenterLeftTwelfth: return "middleCenterLeftTwelfth"
        case .middleCenterRightTwelfth: return "middleCenterRightTwelfth"
        case .middleRightTwelfth: return "middleRightTwelfth"
        case .bottomLeftTwelfth: return "bottomLeftTwelfth"
        case .bottomCenterLeftTwelfth: return "bottomCenterLeftTwelfth"
        case .bottomCenterRightTwelfth: return "bottomCenterRightTwelfth"
        case .bottomRightTwelfth: return "bottomRightTwelfth"
        case .topLeftSixteenth: return "topLeftSixteenth"
        case .topCenterLeftSixteenth: return "topCenterLeftSixteenth"
        case .topCenterRightSixteenth: return "topCenterRightSixteenth"
        case .topRightSixteenth: return "topRightSixteenth"
        case .upperMiddleLeftSixteenth: return "upperMiddleLeftSixteenth"
        case .upperMiddleCenterLeftSixteenth: return "upperMiddleCenterLeftSixteenth"
        case .upperMiddleCenterRightSixteenth: return "upperMiddleCenterRightSixteenth"
        case .upperMiddleRightSixteenth: return "upperMiddleRightSixteenth"
        case .lowerMiddleLeftSixteenth: return "lowerMiddleLeftSixteenth"
        case .lowerMiddleCenterLeftSixteenth: return "lowerMiddleCenterLeftSixteenth"
        case .lowerMiddleCenterRightSixteenth: return "lowerMiddleCenterRightSixteenth"
        case .lowerMiddleRightSixteenth: return "lowerMiddleRightSixteenth"
        case .bottomLeftSixteenth: return "bottomLeftSixteenth"
        case .bottomCenterLeftSixteenth: return "bottomCenterLeftSixteenth"
        case .bottomCenterRightSixteenth: return "bottomCenterRightSixteenth"
        case .bottomRightSixteenth: return "bottomRightSixteenth"
        case .displayOne: return "displayOne"
        case .displayTwo: return "displayTwo"
        case .displayThree: return "displayThree"
        case .displayFour: return "displayFour"
        case .displayFive: return "displayFive"
        case .displaySix: return "displaySix"
        case .displaySeven: return "displaySeven"
        case .displayEight: return "displayEight"
        case .displayNine: return "displayNine"
        }
    }

    var aliasName: String? {
        switch self {
        case .leftHalf: return "leftSide"
        case .rightHalf: return "rightSide"
        case .bottomHalf: return "bottomSide"
        case .topHalf: return "topSide"
        case .centerHalf: return "centerSection"
        default: return nil
        }
    }

    var displayIndex: Int? {
        switch self {
        case .displayOne: return 0
        case .displayTwo: return 1
        case .displayThree: return 2
        case .displayFour: return 3
        case .displayFive: return 4
        case .displaySix: return 5
        case .displaySeven: return 6
        case .displayEight: return 7
        case .displayNine: return 8
        default: return nil
        }
    }

    var displayName: String? {
        switch self {
        case .leftHalf:
            L("Left")
        case .rightHalf:
            L("Right")
        case .maximize:
            L("Maximize")
        case .maximizeHeight:
            L("Maximize Height")
        case .previousDisplay:
            L("Previous Display")
        case .nextDisplay:
            L("Next Display")
        case .larger:
            L("Make Larger")
        case .smaller:
            L("Make Smaller")
        case .bottomHalf:
            L("Bottom")
        case .topHalf:
            L("Top")
        case .center:
            L("Move to Center")
        case .bottomLeft:
            L("Bottom Left")
        case .bottomRight:
            L("Bottom Right")
        case .topLeft:
            L("Top Left")
        case .topRight:
            L("Top Right")
        case .restore:
            L("Restore")
        case .firstThird:
            L("First Third")
        case .firstTwoThirds:
            L("First Two Thirds")
        case .centerThird:
            L("Center Third")
        case .centerTwoThirds:
            L("Center Two Thirds")
        case .lastTwoThirds:
            L("Last Two Thirds")
        case .lastThird:
            L("Last Third")
        case .moveLeft:
            L("Move Left")
        case .moveRight:
            L("Move Right")
        case .moveUp:
            L("Move Up")
        case .moveDown:
            L("Move Down")
        case .almostMaximize:
            L("Almost Maximize")
        case .centerHalf:
            L("Center")
        case .firstFourth:
            L("First Fourth")
        case .secondFourth:
            L("Second Fourth")
        case .thirdFourth:
            L("Third Fourth")
        case .lastFourth:
            L("Last Fourth")
        case .firstThreeFourths:
            L("First Three Fourths")
        case .centerThreeFourths:
            L("Center Three Fourths")
        case .lastThreeFourths:
            L("Last Three Fourths")
        case .topLeftSixth:
            L("Top Left Sixth")
        case .topCenterSixth:
            L("Top Center Sixth")
        case .topRightSixth:
            L("Top Right Sixth")
        case .bottomLeftSixth:
            L("Bottom Left Sixth")
        case .bottomCenterSixth:
            L("Bottom Center Sixth")
        case .bottomRightSixth:
            L("Bottom Right Sixth")
        case .topLeftNinth:
            L("Top Left Ninth")
        case .topCenterNinth:
            L("Top Center Ninth")
        case .topRightNinth:
            L("Top Right Ninth")
        case .middleLeftNinth:
            L("Middle Left Ninth")
        case .middleCenterNinth:
            L("Middle Center Ninth")
        case .middleRightNinth:
            L("Middle Right Ninth")
        case .bottomLeftNinth:
            L("Bottom Left Ninth")
        case .bottomCenterNinth:
            L("Bottom Center Ninth")
        case .bottomRightNinth:
            L("Bottom Right Ninth")
        case .topLeftEighth:
            L("Top Left 8th")
        case .topCenterLeftEighth:
            L("Top Center Left 8th")
        case .topCenterRightEighth:
            L("Top Center Right 8th")
        case .topRightEighth:
            L("Top Right 8th")
        case .bottomLeftEighth:
            L("Bottom Left 8th")
        case .bottomCenterLeftEighth:
            L("Bottom Center Left 8th")
        case .bottomCenterRightEighth:
            L("Bottom Center Right 8th")
        case .bottomRightEighth:
            L("Bottom Right 8th")
        case .firstVerticalEighth:
            L("First Vertical Eighth")
        case .secondVerticalEighth:
            L("Second Vertical Eighth")
        case .thirdVerticalEighth:
            L("Third Vertical Eighth")
        case .fourthVerticalEighth:
            L("Fourth Vertical Eighth")
        case .fifthVerticalEighth:
            L("Fifth Vertical Eighth")
        case .sixthVerticalEighth:
            L("Sixth Vertical Eighth")
        case .seventhVerticalEighth:
            L("Seventh Vertical Eighth")
        case .lastVerticalEighth:
            L("Last Vertical Eighth")
        case .firstVerticalSixth:
            L("First Vertical Sixth")
        case .secondVerticalSixth:
            L("Second Vertical Sixth")
        case .thirdVerticalSixth:
            L("Third Vertical Sixth")
        case .fourthVerticalSixth:
            L("Fourth Vertical Sixth")
        case .fifthVerticalSixth:
            L("Fifth Vertical Sixth")
        case .lastVerticalSixth:
            L("Last Vertical Sixth")
        case .tileRows:
            L("Tile in Rows")
        case .tileColumns:
            L("Tile in Columns")
        case .cycleStackedWindows:
            L("Cycle Stacked Windows")
        case .cycleStackedWindowsBackward:
            L("Cycle Stacked Windows Backward")
        case .largerWidth:
            L("Larger Width")
        case .smallerWidth:
            L("Smaller Width")
        case .topVerticalThird:
            L("Top Third")
        case .middleVerticalThird:
            L("Middle Third")
        case .bottomVerticalThird:
            L("Bottom Third")
        case .topVerticalTwoThirds:
            L("Top Two Thirds")
        case .bottomVerticalTwoThirds:
            L("Bottom Two Thirds")
        case .topLeftTwelfth:
            L("Top Left Twelfth")
        case .topCenterLeftTwelfth:
            L("Top Center Left Twelfth")
        case .topCenterRightTwelfth:
            L("Top Center Right Twelfth")
        case .topRightTwelfth:
            L("Top Right Twelfth")
        case .middleLeftTwelfth:
            L("Middle Left Twelfth")
        case .middleCenterLeftTwelfth:
            L("Middle Center Left Twelfth")
        case .middleCenterRightTwelfth:
            L("Middle Center Right Twelfth")
        case .middleRightTwelfth:
            L("Middle Right Twelfth")
        case .bottomLeftTwelfth:
            L("Bottom Left Twelfth")
        case .bottomCenterLeftTwelfth:
            L("Bottom Center Left Twelfth")
        case .bottomCenterRightTwelfth:
            L("Bottom Center Right Twelfth")
        case .bottomRightTwelfth:
            L("Bottom Right Twelfth")
        case .topLeftSixteenth:
            L("Top Left Sixteenth")
        case .topCenterLeftSixteenth:
            L("Top Center Left Sixteenth")
        case .topCenterRightSixteenth:
            L("Top Center Right Sixteenth")
        case .topRightSixteenth:
            L("Top Right Sixteenth")
        case .upperMiddleLeftSixteenth:
            L("Upper Middle Left Sixteenth")
        case .upperMiddleCenterLeftSixteenth:
            L("Upper Middle Center Left Sixteenth")
        case .upperMiddleCenterRightSixteenth:
            L("Upper Middle Center Right Sixteenth")
        case .upperMiddleRightSixteenth:
            L("Upper Middle Right Sixteenth")
        case .lowerMiddleLeftSixteenth:
            L("Lower Middle Left Sixteenth")
        case .lowerMiddleCenterLeftSixteenth:
            L("Lower Middle Center Left Sixteenth")
        case .lowerMiddleCenterRightSixteenth:
            L("Lower Middle Center Right Sixteenth")
        case .lowerMiddleRightSixteenth:
            L("Lower Middle Right Sixteenth")
        case .bottomLeftSixteenth:
            L("Bottom Left Sixteenth")
        case .bottomCenterLeftSixteenth:
            L("Bottom Center Left Sixteenth")
        case .bottomCenterRightSixteenth:
            L("Bottom Center Right Sixteenth")
        case .bottomRightSixteenth:
            L("Bottom Right Sixteenth")

        case .topLeftThird, .topRightThird, .bottomLeftThird, .bottomRightThird,
             .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight,
             .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight,
             .specified, .reverseAll, .tileAll, .cascadeAll, .leftTodo, .rightTodo,
             .cascadeActiveApp, .tileActiveApp,
             .centerProminently, .largerHeight, .smallerHeight,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            nil
        }
    }
    
    var settingsDisplayName: String? {
        switch self {
        case .topLeftNinth:
            return L("Ninths (3x3)")
        case .topLeftTwelfth:
            return L("Twelfths (3x4)")
        case .topLeftSixteenth:
            return L("Sixteenths (4x4)")
        default: return nil
        }
    }

    var notificationName: Notification.Name {
        return Notification.Name("RunTime.window." + name)
    }

    var resizes: Bool {
        switch self {
        case .center, .centerProminently, .nextDisplay, .previousDisplay,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine: return false
        case .moveUp, .moveDown, .moveLeft, .moveRight: return Defaults.resizeOnDirectionalMove.enabled
        default: return true
        }
    }
    
    var allowedToExtendOutsideCurrentScreenArea: Bool {
        switch self {
        case .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight:
            return true
        default:
            return false
        }
    }
    
    var isDragSnappable: Bool {
        switch self {
        case .restore, .previousDisplay, .nextDisplay, .moveUp, .moveDown, .moveLeft, .moveRight, .specified, .reverseAll, .tileAll, .tileRows, .tileColumns, .cascadeAll, .larger, .smaller, .largerWidth, .smallerWidth, .cascadeActiveApp, .tileActiveApp,
            .cycleStackedWindows, .cycleStackedWindowsBackward,
            .firstVerticalEighth, .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth,
            .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth, .lastVerticalEighth,
            .firstVerticalSixth, .secondVerticalSixth, .thirdVerticalSixth,
            .fourthVerticalSixth, .fifthVerticalSixth, .lastVerticalSixth,
            // Ninths
            .topLeftNinth, .topCenterNinth, .topRightNinth, .middleLeftNinth, .middleCenterNinth, .middleRightNinth, .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth,
            // Corner thirds
            .topLeftThird, .topRightThird, .bottomLeftThird, .bottomRightThird,
            // Specific displays
            .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
            .displaySix, .displaySeven, .displayEight, .displayNine:
            return false
        default:
            return true
        }
    }

    var spectacleDefault: Shortcut? {
        switch self {
        case .leftHalf: return Shortcut( cmd|alt, kVK_LeftArrow )
        case .rightHalf: return Shortcut( cmd|alt, kVK_RightArrow )
        case .maximize: return Shortcut( cmd|alt, kVK_ANSI_F )
        case .maximizeHeight: return Shortcut( ctrl|alt|shift, kVK_UpArrow )
        case .previousDisplay: return Shortcut( ctrl|alt|cmd, kVK_LeftArrow )
        case .nextDisplay:  return Shortcut( ctrl|alt|cmd, kVK_RightArrow )
        case .larger: return Shortcut( ctrl|alt|shift, kVK_RightArrow )
        case .smaller: return Shortcut( ctrl|alt|shift, kVK_LeftArrow )
        case .bottomHalf: return Shortcut( cmd|alt, kVK_DownArrow )
        case .topHalf: return Shortcut( cmd|alt, kVK_UpArrow )
        case .center: return Shortcut( alt|cmd, kVK_ANSI_C )
        case .bottomLeft: return Shortcut( cmd|ctrl|shift, kVK_LeftArrow )
        case .bottomRight: return Shortcut( cmd|ctrl|shift, kVK_RightArrow )
        case .topLeft: return Shortcut( ctrl|cmd, kVK_LeftArrow )
        case .topRight: return Shortcut( ctrl|cmd, kVK_RightArrow )
        case .restore: return Shortcut( ctrl|alt, kVK_Delete)
        default: return nil
        }
    }

    var alternateDefault: Shortcut? {
        switch self {
        case .leftHalf: return Shortcut( ctrl|alt, kVK_LeftArrow )
        case .rightHalf: return Shortcut( ctrl|alt, kVK_RightArrow )
        case .bottomHalf: return Shortcut( ctrl|alt, kVK_DownArrow )
        case .topHalf: return Shortcut( ctrl|alt, kVK_UpArrow )
        case .bottomLeft: return Shortcut( ctrl|alt, kVK_ANSI_J )
        case .bottomRight: return Shortcut( ctrl|alt, kVK_ANSI_K )
        case .topLeft: return Shortcut( ctrl|alt, kVK_ANSI_U )
        case .topRight: return Shortcut( ctrl|alt, kVK_ANSI_I )
        case .maximize: return Shortcut( ctrl|alt, kVK_Return )
        case .maximizeHeight: return Shortcut( ctrl|alt|shift, kVK_UpArrow )
        case .previousDisplay: return Shortcut( ctrl|alt|cmd, kVK_LeftArrow )
        case .nextDisplay: return Shortcut( ctrl|alt|cmd, kVK_RightArrow )
        case .larger: return Shortcut( ctrl|alt, kVK_ANSI_Equal )
        case .smaller: return Shortcut( ctrl|alt, kVK_ANSI_Minus )
        case .center: return Shortcut( ctrl|alt, kVK_ANSI_C )
        case .restore: return Shortcut( ctrl|alt, kVK_Delete)
        case .firstThird: return Shortcut( ctrl|alt, kVK_ANSI_D )
        case .firstTwoThirds: return Shortcut( ctrl|alt, kVK_ANSI_E )
        case .centerThird: return Shortcut( ctrl|alt, kVK_ANSI_F )
        case .lastTwoThirds: return Shortcut( ctrl|alt, kVK_ANSI_T )
        case .lastThird: return Shortcut( ctrl|alt, kVK_ANSI_G )
        case .centerTwoThirds:
            if let installVersion = Defaults.installVersion.value,
               let intInstallVersion = Int(installVersion),
               intInstallVersion > 94 {
                return Shortcut( ctrl|alt, kVK_ANSI_R )
            }
            return nil
        default: return nil
        }
    }

    var image: NSImage {
        switch self {
        case .leftHalf: return NSImage.windowKit("leftHalfTemplate")
        case .rightHalf: return NSImage.windowKit("rightHalfTemplate")
        case .maximize: return NSImage.windowKit("maximizeTemplate")
        case .maximizeHeight: return NSImage.windowKit("maximizeHeightTemplate")
        case .previousDisplay: return NSImage.windowKit("prevDisplayTemplate")
        case .nextDisplay: return NSImage.windowKit("nextDisplayTemplate")
        case .larger: return NSImage.windowKit("makeLargerTemplate")
        case .smaller: return NSImage.windowKit("makeSmallerTemplate")
        case .bottomHalf: return NSImage.windowKit("bottomHalfTemplate")
        case .topHalf: return NSImage.windowKit("topHalfTemplate")
        case .center: return NSImage.windowKit("centerTemplate")
        case .bottomLeft: return NSImage.windowKit("bottomLeftTemplate")
        case .bottomRight: return NSImage.windowKit("bottomRightTemplate")
        case .topLeft: return NSImage.windowKit("topLeftTemplate")
        case .topRight: return NSImage.windowKit("topRightTemplate")
        case .restore: return NSImage.windowKit("restoreTemplate")
        case .firstThird: return NSImage.windowKit("firstThirdTemplate")
        case .firstTwoThirds: return NSImage.windowKit("firstTwoThirdsTemplate")
        case .centerThird: return NSImage.windowKit("centerThirdTemplate")
        case .centerTwoThirds: return NSImage.windowKit("centerTwoThirdsTemplate")
        case .lastTwoThirds: return NSImage.windowKit("lastTwoThirdsTemplate")
        case .lastThird: return NSImage.windowKit("lastThirdTemplate")
        case .moveLeft: return NSImage.windowKit("moveLeftTemplate")
        case .moveRight: return NSImage.windowKit("moveRightTemplate")
        case .moveUp: return NSImage.windowKit("moveUpTemplate")
        case .moveDown: return NSImage.windowKit("moveDownTemplate")
        case .almostMaximize: return NSImage.windowKit("almostMaximizeTemplate")
        case .centerHalf: return NSImage.windowKit("halfWidthCenterTemplate")
        case .firstFourth: return NSImage.windowKit("leftFourthTemplate")
        case .secondFourth: return NSImage.windowKit("centerLeftFourthTemplate")
        case .thirdFourth: return NSImage.windowKit("centerRightFourthTemplate")
        case .lastFourth: return NSImage.windowKit("rightFourthTemplate")
        case .firstThreeFourths: return NSImage.windowKit("firstThreeFourthsTemplate")
        case .centerThreeFourths: return NSImage.windowKit("centerThreeFourthsTemplate")
        case .lastThreeFourths: return NSImage.windowKit("lastThreeFourthsTemplate")
        case .topLeftSixth: return NSImage.windowKit("topLeftSixthTemplate")
        case .topCenterSixth: return NSImage.windowKit("topCenterSixthTemplate")
        case .topRightSixth: return NSImage.windowKit("topRightSixthTemplate")
        case .bottomLeftSixth: return NSImage.windowKit("bottomLeftSixthTemplate")
        case .bottomCenterSixth: return NSImage.windowKit("bottomCenterSixthTemplate")
        case .bottomRightSixth: return NSImage.windowKit("bottomRightSixthTemplate")
        case .topLeftNinth: return NSImage.windowKit("topLeftNinthTemplate")
        case .topCenterNinth: return NSImage.windowKit("topCenterNinthTemplate")
        case .topRightNinth: return NSImage.windowKit("topRightNinthTemplate")
        case .middleLeftNinth: return NSImage.windowKit("middleLeftNinthTemplate")
        case .middleCenterNinth: return NSImage.windowKit("middleCenterNinthTemplate")
        case .middleRightNinth: return NSImage.windowKit("middleRightNinthTemplate")
        case .bottomLeftNinth: return NSImage.windowKit("bottomLeftNinthTemplate")
        case .bottomCenterNinth: return NSImage.windowKit("bottomCenterNinthTemplate")
        case .bottomRightNinth: return NSImage.windowKit("bottomRightNinthTemplate")
        case .topLeftThird: return NSImage()
        case .topRightThird: return NSImage()
        case .bottomLeftThird: return NSImage()
        case .bottomRightThird: return NSImage()
        case .topLeftEighth: return NSImage.windowKit("tlEighthTemplate")
        case .topCenterLeftEighth: return NSImage.windowKit("ctlEighthTemplate")
        case .topCenterRightEighth: return NSImage.windowKit("ctrEighthTemplate")
        case .topRightEighth: return NSImage.windowKit("trEighthTemplate")
        case .bottomLeftEighth: return NSImage.windowKit("blEighthTemplate")
        case .bottomCenterLeftEighth: return NSImage.windowKit("cblEighthTemplate")
        case .bottomCenterRightEighth: return NSImage.windowKit("cbrEighthTemplate")
        case .bottomRightEighth: return NSImage.windowKit("brEighthTemplate")
        case .firstVerticalEighth, .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth,
             .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth, .lastVerticalEighth:
            return NSImage()
        case .firstVerticalSixth: return NSImage.windowKit("firstVerticalSixthTemplate")
        case .secondVerticalSixth: return NSImage.windowKit("secondVerticalSixthTemplate")
        case .thirdVerticalSixth: return NSImage.windowKit("thirdVerticalSixthTemplate")
        case .fourthVerticalSixth: return NSImage.windowKit("fourthVerticalSixthTemplate")
        case .fifthVerticalSixth: return NSImage.windowKit("fifthVerticalSixthTemplate")
        case .lastVerticalSixth: return NSImage.windowKit("lastVerticalSixthTemplate")
        case .doubleHeightUp: return  NSImage()
        case .doubleHeightDown: return  NSImage()
        case .doubleWidthLeft: return  NSImage()
        case .doubleWidthRight: return  NSImage()
        case .halveHeightUp: return  NSImage()
        case .halveHeightDown: return  NSImage()
        case .halveWidthLeft: return  NSImage()
        case .halveWidthRight: return  NSImage()
        case .specified, .reverseAll: return NSImage()
        case .tileAll: return NSImage()
        case .tileRows: return NSImage.windowKit("tileRowsTemplate")
        case .tileColumns: return NSImage.windowKit("tileColumnsTemplate")
        case .cycleStackedWindows, .cycleStackedWindowsBackward: return NSImage()
        case .cascadeAll: return NSImage()
        case .leftTodo: return NSImage()
        case .rightTodo: return NSImage()
        case .cascadeActiveApp: return NSImage()
        case .tileActiveApp: return NSImage()
        case .centerProminently: return NSImage()
        case .largerWidth: return NSImage.windowKit("largerWidthTemplate")
        case .smallerWidth: return NSImage.windowKit("smallerWidthTemplate")
        case .largerHeight: return NSImage()
        case .smallerHeight: return NSImage()
        case .topVerticalThird: return NSImage.windowKit("topThirdTemplate")
        case .middleVerticalThird: return NSImage.windowKit("centerThirdHorizontalTemplate")
        case .bottomVerticalThird: return NSImage.windowKit("bottomThirdTemplate")
        case .topVerticalTwoThirds: return NSImage.windowKit("topTwoThirdsTemplate")
        case .bottomVerticalTwoThirds: return NSImage.windowKit("bottomTwoThirdsTemplate")
        case .topLeftTwelfth: return NSImage.windowKit("topLeftTwelfthTemplate")
        case .topCenterLeftTwelfth: return NSImage.windowKit("topCenterLeftTwelfthTemplate")
        case .topCenterRightTwelfth: return NSImage.windowKit("topCenterRightTwelfthTemplate")
        case .topRightTwelfth: return NSImage.windowKit("topRightTwelfthTemplate")
        case .middleLeftTwelfth: return NSImage.windowKit("middleLeftTwelfthTemplate")
        case .middleCenterLeftTwelfth: return NSImage.windowKit("middleCenterLeftTwelfthTemplate")
        case .middleCenterRightTwelfth: return NSImage.windowKit("middleCenterRightTwelfthTemplate")
        case .middleRightTwelfth: return NSImage.windowKit("middleRightTwelfthTemplate")
        case .bottomLeftTwelfth: return NSImage.windowKit("bottomLeftTwelfthTemplate")
        case .bottomCenterLeftTwelfth: return NSImage.windowKit("bottomCenterLeftTwelfthTemplate")
        case .bottomCenterRightTwelfth: return NSImage.windowKit("bottomCenterRightTwelfthTemplate")
        case .bottomRightTwelfth: return NSImage.windowKit("bottomRightTwelfthTemplate")
        case .topLeftSixteenth: return NSImage.windowKit("topLeftSixteenthTemplate")
        case .topCenterLeftSixteenth: return NSImage.windowKit("topCenterLeftSixteenthTemplate")
        case .topCenterRightSixteenth: return NSImage.windowKit("topCenterRightSixteenthTemplate")
        case .topRightSixteenth: return NSImage.windowKit("topRightSixteenthTemplate")
        case .upperMiddleLeftSixteenth: return NSImage.windowKit("upperMiddleLeftSixteenthTemplate")
        case .upperMiddleCenterLeftSixteenth: return NSImage.windowKit("upperMiddleCenterLeftSixteenthTemplate")
        case .upperMiddleCenterRightSixteenth: return NSImage.windowKit("upperMiddleCenterRightSixteenthTemplate")
        case .upperMiddleRightSixteenth: return NSImage.windowKit("upperMiddleRightSixteenthTemplate")
        case .lowerMiddleLeftSixteenth: return NSImage.windowKit("lowerMiddleLeftSixteenthTemplate")
        case .lowerMiddleCenterLeftSixteenth: return NSImage.windowKit("lowerMiddleCenterLeftSixteenthTemplate")
        case .lowerMiddleCenterRightSixteenth: return NSImage.windowKit("lowerMiddleCenterRightSixteenthTemplate")
        case .lowerMiddleRightSixteenth: return NSImage.windowKit("lowerMiddleRightSixteenthTemplate")
        case .bottomLeftSixteenth: return NSImage.windowKit("bottomLeftSixteenthTemplate")
        case .bottomCenterLeftSixteenth: return NSImage.windowKit("bottomCenterLeftSixteenthTemplate")
        case .bottomCenterRightSixteenth: return NSImage.windowKit("bottomCenterRightSixteenthTemplate")
        case .bottomRightSixteenth: return NSImage.windowKit("bottomRightSixteenthTemplate")
        case .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return NSImage.windowKit("nextDisplayTemplate")
        }
    }

    var gapSharedEdge: Edge {
        switch self {
        case .leftHalf: return .right
        case .rightHalf: return .left
        case .bottomHalf: return .top
        case .topHalf: return .bottom
        case .bottomLeft: return [.top, .right]
        case .bottomRight: return [.top, .left]
        case .topLeft: return [.bottom, .right]
        case .topRight: return [.bottom, .left]
        case .firstVerticalEighth: return .right
        case .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth,
             .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth: return [.left, .right]
        case .lastVerticalEighth: return .left
        case .firstVerticalSixth: return .right
        case .secondVerticalSixth, .thirdVerticalSixth, .fourthVerticalSixth, .fifthVerticalSixth: return [.left, .right]
        case .lastVerticalSixth: return .left
        case .moveUp: return Defaults.resizeOnDirectionalMove.enabled ? .bottom : .none
        case .moveDown: return Defaults.resizeOnDirectionalMove.enabled ? .top : .none
        case .moveLeft: return Defaults.resizeOnDirectionalMove.enabled ? .right : .none
        case .moveRight: return Defaults.resizeOnDirectionalMove.enabled ? .left : .none
        default:
            return .none
        }
    }

    var gapsApplicable: Dimension {
        switch self {
        case .leftHalf, .rightHalf, .bottomHalf, .topHalf, .centerHalf, .bottomLeft, .bottomRight, .topLeft, .topRight, .firstThird, .firstTwoThirds, .centerThird, .centerTwoThirds, .lastTwoThirds, .lastThird,
                .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths, .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
            .topLeftNinth, .topCenterNinth, .topRightNinth, .middleLeftNinth, .middleCenterNinth, .middleRightNinth, .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth,
            .topLeftThird, .topRightThird, .bottomLeftThird, .bottomRightThird,
            .topLeftEighth, .topCenterLeftEighth, .topCenterRightEighth, .topRightEighth,
            .bottomLeftEighth, .bottomCenterLeftEighth, .bottomCenterRightEighth, .bottomRightEighth,
            .firstVerticalEighth, .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth,
            .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth, .lastVerticalEighth,
            .firstVerticalSixth, .secondVerticalSixth, .thirdVerticalSixth,
            .fourthVerticalSixth, .fifthVerticalSixth, .lastVerticalSixth,
            .topLeftTwelfth, .topCenterLeftTwelfth, .topCenterRightTwelfth, .topRightTwelfth,
            .middleLeftTwelfth, .middleCenterLeftTwelfth, .middleCenterRightTwelfth, .middleRightTwelfth,
            .bottomLeftTwelfth, .bottomCenterLeftTwelfth, .bottomCenterRightTwelfth, .bottomRightTwelfth,
            .topLeftSixteenth, .topCenterLeftSixteenth, .topCenterRightSixteenth, .topRightSixteenth,
            .upperMiddleLeftSixteenth, .upperMiddleCenterLeftSixteenth, .upperMiddleCenterRightSixteenth, .upperMiddleRightSixteenth,
            .lowerMiddleLeftSixteenth, .lowerMiddleCenterLeftSixteenth, .lowerMiddleCenterRightSixteenth, .lowerMiddleRightSixteenth,
            .bottomLeftSixteenth, .bottomCenterLeftSixteenth, .bottomCenterRightSixteenth, .bottomRightSixteenth,
             .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight,
             .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight,
            .leftTodo, .rightTodo,
            .topVerticalThird, .middleVerticalThird, .bottomVerticalThird, .topVerticalTwoThirds, .bottomVerticalTwoThirds:
            return .both
        case .moveUp, .moveDown:
            return Defaults.resizeOnDirectionalMove.enabled ? .vertical : .none;
        case .moveLeft, .moveRight:
            return Defaults.resizeOnDirectionalMove.enabled ? .horizontal : .none;
        case .maximize:
            return Defaults.applyGapsToMaximize.userDisabled ? .none : .both;
        case .maximizeHeight:
            return Defaults.applyGapsToMaximizeHeight.userDisabled ? .none : .vertical;
        case .almostMaximize, .previousDisplay, .nextDisplay, .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight, .center, .centerProminently, .restore, .specified, .reverseAll, .tileAll, .tileRows, .tileColumns, .cascadeAll, .cascadeActiveApp, .tileActiveApp,
             .cycleStackedWindows, .cycleStackedWindowsBackward,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return .none
        }
    }

    var positionCycles: Bool {
        switch self {
        case .maximize, .almostMaximize, .maximizeHeight,
             .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight,
             .center, .centerProminently,
             .restore,
             .nextDisplay, .previousDisplay,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine,
             .moveLeft, .moveRight, .moveUp, .moveDown,
             .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight,
             .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight,
             .reverseAll, .tileAll, .tileRows, .tileColumns, .cascadeAll, .cascadeActiveApp, .tileActiveApp,
             .cycleStackedWindows, .cycleStackedWindowsBackward,
             .leftTodo, .rightTodo,
             .specified:
            return false
        default:
            return true
        }
    }

    /// Whether landing on another window in this position should be offset so
    /// the covered window stays visible. Cycling positions qualify, and so
    /// does maximize: it doesn't cycle, but two maximized windows still land
    /// exactly on top of each other.
    var overlapOffsetApplies: Bool {
        positionCycles || self == .maximize
    }

    var category: WindowActionCategory? { // used to specify a submenu
        switch self {
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: return .thirds
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths: return .fourths
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
             .firstVerticalSixth, .secondVerticalSixth, .thirdVerticalSixth, .fourthVerticalSixth, .fifthVerticalSixth, .lastVerticalSixth: return .sixths
        case .topLeftEighth, .topCenterLeftEighth, .topCenterRightEighth, .topRightEighth, .bottomLeftEighth, .bottomCenterLeftEighth, .bottomCenterRightEighth, .bottomRightEighth,
             .firstVerticalEighth, .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth, .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth, .lastVerticalEighth: return .eighths
        case .topLeftNinth, .topCenterNinth, .topRightNinth, .middleLeftNinth, .middleCenterNinth, .middleRightNinth, .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth: return .ninths
        case .topLeftTwelfth, .topCenterLeftTwelfth, .topCenterRightTwelfth, .topRightTwelfth, .middleLeftTwelfth, .middleCenterLeftTwelfth, .middleCenterRightTwelfth, .middleRightTwelfth, .bottomLeftTwelfth, .bottomCenterLeftTwelfth, .bottomCenterRightTwelfth, .bottomRightTwelfth: return .twelfths
        case .topLeftSixteenth, .topCenterLeftSixteenth, .topCenterRightSixteenth, .topRightSixteenth, .upperMiddleLeftSixteenth, .upperMiddleCenterLeftSixteenth, .upperMiddleCenterRightSixteenth, .upperMiddleRightSixteenth, .lowerMiddleLeftSixteenth, .lowerMiddleCenterLeftSixteenth, .lowerMiddleCenterRightSixteenth, .lowerMiddleRightSixteenth, .bottomLeftSixteenth, .bottomCenterLeftSixteenth, .bottomCenterRightSixteenth, .bottomRightSixteenth: return .sixteenths
        case .tileRows, .tileColumns: return .tiling
        case .moveUp, .moveDown, .moveLeft, .moveRight: return .move
        case .almostMaximize, .maximizeHeight, .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight: return .size
        default: return nil
        }
    }

    var classification: WindowActionCategory? {
        switch self {
        case .firstThird, .firstTwoThirds, .centerThird, .centerTwoThirds, .lastTwoThirds, .lastThird:
            return .thirds
        case .smaller, .larger, .smallerWidth, .largerWidth, .smallerHeight, .largerHeight:
            return .size
        case .previousDisplay, .nextDisplay,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return .display
        default: return nil
        }
    }
}

enum SubWindowAction {
    case leftThird,
    centerVerticalThird,
    rightThird,
    leftTwoThirds,
    rightTwoThirds,
    
    topThird,
    centerHorizontalThird,
    bottomThird,
    topTwoThirds,
    bottomTwoThirds,
    
    leftFourth,
    centerLeftFourth,
    centerRightFourth,
    rightFourth,
    
    topFourth,
    centerTopFourth,
    centerBottomFourth,
    bottomFourth,
    
    rightThreeFourths,
    bottomThreeFourths,
    leftThreeFourths,
    topThreeFourths,
    centerVerticalThreeFourths,
    centerHorizontalThreeFourths,
    
    centerVerticalHalf,
    centerHorizontalHalf,
    
    topLeftSixthLandscape,
    topCenterSixthLandscape,
    topRightSixthLandscape,
    bottomLeftSixthLandscape,
    bottomCenterSixthLandscape,
    bottomRightSixthLandscape,
    
    topLeftSixthPortrait,
    topRightSixthPortrait,
    leftCenterSixthPortrait,
    rightCenterSixthPortrait,
    bottomLeftSixthPortrait,
    bottomRightSixthPortrait,
    
    topLeftTwoSixthsLandscape,
    topLeftTwoSixthsPortrait,
    topRightTwoSixthsLandscape,
    topRightTwoSixthsPortrait,
    
    bottomLeftTwoSixthsLandscape,
    bottomLeftTwoSixthsPortrait,
    bottomRightTwoSixthsLandscape,
    bottomRightTwoSixthsPortrait,
    
    topLeftNinth,
    topCenterNinth,
    topRightNinth,
    middleLeftNinth,
    middleCenterNinth,
    middleRightNinth,
    bottomLeftNinth,
    bottomCenterNinth,
    bottomRightNinth,
         
    topLeftThird,
    topRightThird,
    bottomLeftThird,
    bottomRightThird,

    topLeftQuarter,
    topRightQuarter,
    bottomLeftQuarter,
    bottomRightQuarter,

    topLeftEighth,
    topCenterLeftEighth,
    topCenterRightEighth,
    topRightEighth,
    bottomLeftEighth,
    bottomCenterLeftEighth,
    bottomCenterRightEighth,
    bottomRightEighth,

    firstVerticalEighthLandscape,
    secondVerticalEighthLandscape,
    thirdVerticalEighthLandscape,
    fourthVerticalEighthLandscape,
    fifthVerticalEighthLandscape,
    sixthVerticalEighthLandscape,
    seventhVerticalEighthLandscape,
    lastVerticalEighthLandscape,

    firstVerticalEighthPortrait,
    secondVerticalEighthPortrait,
    thirdVerticalEighthPortrait,
    fourthVerticalEighthPortrait,
    fifthVerticalEighthPortrait,
    sixthVerticalEighthPortrait,
    seventhVerticalEighthPortrait,
    lastVerticalEighthPortrait,

    firstVerticalSixthLandscape,
    secondVerticalSixthLandscape,
    thirdVerticalSixthLandscape,
    fourthVerticalSixthLandscape,
    fifthVerticalSixthLandscape,
    lastVerticalSixthLandscape,

    firstVerticalSixthPortrait,
    secondVerticalSixthPortrait,
    thirdVerticalSixthPortrait,
    fourthVerticalSixthPortrait,
    fifthVerticalSixthPortrait,
    lastVerticalSixthPortrait,

    topLeftTwelfth,
    topCenterLeftTwelfth,
    topCenterRightTwelfth,
    topRightTwelfth,
    middleLeftTwelfth,
    middleCenterLeftTwelfth,
    middleCenterRightTwelfth,
    middleRightTwelfth,
    bottomLeftTwelfth,
    bottomCenterLeftTwelfth,
    bottomCenterRightTwelfth,
    bottomRightTwelfth,

    topLeftSixteenth,
    topCenterLeftSixteenth,
    topCenterRightSixteenth,
    topRightSixteenth,
    upperMiddleLeftSixteenth,
    upperMiddleCenterLeftSixteenth,
    upperMiddleCenterRightSixteenth,
    upperMiddleRightSixteenth,
    lowerMiddleLeftSixteenth,
    lowerMiddleCenterLeftSixteenth,
    lowerMiddleCenterRightSixteenth,
    lowerMiddleRightSixteenth,
    bottomLeftSixteenth,
    bottomCenterLeftSixteenth,
    bottomCenterRightSixteenth,
    bottomRightSixteenth,

    maximize,
    
    leftTodo,
    rightTodo

    var gapSharedEdge: Edge {
        switch self {
        case .leftThird: return .right
        case .centerVerticalThird: return [.right, .left]
        case .rightThird: return .left
        case .leftTwoThirds: return .right
        case .rightTwoThirds: return .left
        case .topThird: return .bottom
        case .centerHorizontalThird: return [.top, .bottom]
        case .bottomThird: return .top
        case .topTwoThirds: return .bottom
        case .bottomTwoThirds: return .top
        case .leftFourth: return .right
        case .centerLeftFourth: return [.right, .left]
        case .centerRightFourth: return [.right, .left]
        case .rightFourth: return .left
        case .topFourth: return .bottom
        case .centerTopFourth: return [.top, .bottom]
        case .centerBottomFourth: return [.top, .bottom]
        case .bottomFourth: return .top
        case .rightThreeFourths: return .left
        case .bottomThreeFourths: return .top
        case .leftThreeFourths: return .right
        case .topThreeFourths: return .bottom
        case .centerVerticalThreeFourths: return [.right, .left]
        case .centerHorizontalThreeFourths: return [.top, .bottom]
        case .centerVerticalHalf: return [.right, .left]
        case .centerHorizontalHalf: return [.top, .bottom]
        case .topLeftSixthLandscape: return [.right, .bottom]
        case .topCenterSixthLandscape: return [.right, .left, .bottom]
        case .topRightSixthLandscape: return [.left, .bottom]
        case .bottomLeftSixthLandscape: return [.top, .right]
        case .bottomCenterSixthLandscape: return [.left, .right, .top]
        case .bottomRightSixthLandscape: return [.left, .top]
        case .topLeftSixthPortrait: return [.right, .bottom]
        case .topRightSixthPortrait: return [.left, .bottom]
        case .leftCenterSixthPortrait: return [.top, .bottom, .right]
        case .rightCenterSixthPortrait: return [.left, .top, .bottom]
        case .bottomLeftSixthPortrait: return [.top, .right]
        case .bottomRightSixthPortrait: return [.left, .top]
        case .topLeftTwoSixthsLandscape: return [.right, .bottom]
        case .topLeftTwoSixthsPortrait: return [.right, .bottom]
        case .topRightTwoSixthsLandscape: return [.left, .bottom]
        case .topRightTwoSixthsPortrait: return [.left, .bottom]
        case .bottomLeftTwoSixthsLandscape: return [.right, .top]
        case .bottomLeftTwoSixthsPortrait: return [.right, .top]
        case .bottomRightTwoSixthsLandscape: return [.left, .top]
        case .bottomRightTwoSixthsPortrait: return [.left, .top]
        case .topLeftNinth: return [.right, .bottom]
        case .topCenterNinth: return [.right, .left, .bottom]
        case .topRightNinth: return [.left, .bottom]
        case .middleLeftNinth: return [.top, .right, .bottom]
        case .middleCenterNinth: return [.top, .right, .bottom, .left]
        case .middleRightNinth: return [.left, .top, .bottom]
        case .bottomLeftNinth: return [.top, .right]
        case .bottomCenterNinth: return [.left, .top, .right]
        case .bottomRightNinth: return [.left, .top]
        case .topLeftThird: return [.right, .bottom]
        case .topRightThird: return [.left, .bottom]
        case .bottomLeftThird: return [.right, .top]
        case .bottomRightThird: return [.left, .top]
        case .topLeftQuarter: return [.right, .bottom]
        case .topRightQuarter: return [.left, .bottom]
        case .bottomLeftQuarter: return [.right, .top]
        case .bottomRightQuarter: return [.left, .top]
        case .topLeftEighth: return  [.right, .bottom]
        case .topCenterLeftEighth: return  [.right, .left, .bottom]
        case .topCenterRightEighth: return  [.right, .left, .bottom]
        case .topRightEighth: return  [.left, .bottom]
        case .bottomLeftEighth: return  [.right, .top]
        case .bottomCenterLeftEighth: return  [.right, .left, .top]
        case .bottomCenterRightEighth: return  [.right, .left, .top]
        case .bottomRightEighth: return  [.left, .top]
        case .firstVerticalEighthLandscape: return .right
        case .secondVerticalEighthLandscape, .thirdVerticalEighthLandscape, .fourthVerticalEighthLandscape,
             .fifthVerticalEighthLandscape, .sixthVerticalEighthLandscape, .seventhVerticalEighthLandscape:
            return [.left, .right]
        case .lastVerticalEighthLandscape: return .left
        case .firstVerticalEighthPortrait: return .bottom
        case .secondVerticalEighthPortrait, .thirdVerticalEighthPortrait, .fourthVerticalEighthPortrait,
             .fifthVerticalEighthPortrait, .sixthVerticalEighthPortrait, .seventhVerticalEighthPortrait:
            return [.top, .bottom]
        case .lastVerticalEighthPortrait: return .top
        case .firstVerticalSixthLandscape: return .right
        case .secondVerticalSixthLandscape, .thirdVerticalSixthLandscape, .fourthVerticalSixthLandscape, .fifthVerticalSixthLandscape:
            return [.left, .right]
        case .lastVerticalSixthLandscape: return .left
        case .firstVerticalSixthPortrait: return .bottom
        case .secondVerticalSixthPortrait, .thirdVerticalSixthPortrait, .fourthVerticalSixthPortrait, .fifthVerticalSixthPortrait:
            return [.top, .bottom]
        case .lastVerticalSixthPortrait: return .top
        case .topLeftTwelfth: return [.right, .bottom]
        case .topCenterLeftTwelfth: return [.right, .left, .bottom]
        case .topCenterRightTwelfth: return [.right, .left, .bottom]
        case .topRightTwelfth: return [.left, .bottom]
        case .middleLeftTwelfth: return [.top, .right, .bottom]
        case .middleCenterLeftTwelfth: return [.top, .right, .bottom, .left]
        case .middleCenterRightTwelfth: return [.top, .right, .bottom, .left]
        case .middleRightTwelfth: return [.left, .top, .bottom]
        case .bottomLeftTwelfth: return [.top, .right]
        case .bottomCenterLeftTwelfth: return [.left, .top, .right]
        case .bottomCenterRightTwelfth: return [.left, .top, .right]
        case .bottomRightTwelfth: return [.left, .top]
        case .topLeftSixteenth: return [.right, .bottom]
        case .topCenterLeftSixteenth: return [.right, .left, .bottom]
        case .topCenterRightSixteenth: return [.right, .left, .bottom]
        case .topRightSixteenth: return [.left, .bottom]
        case .upperMiddleLeftSixteenth: return [.top, .right, .bottom]
        case .upperMiddleCenterLeftSixteenth: return [.top, .right, .bottom, .left]
        case .upperMiddleCenterRightSixteenth: return [.top, .right, .bottom, .left]
        case .upperMiddleRightSixteenth: return [.left, .top, .bottom]
        case .lowerMiddleLeftSixteenth: return [.top, .right, .bottom]
        case .lowerMiddleCenterLeftSixteenth: return [.top, .right, .bottom, .left]
        case .lowerMiddleCenterRightSixteenth: return [.top, .right, .bottom, .left]
        case .lowerMiddleRightSixteenth: return [.left, .top, .bottom]
        case .bottomLeftSixteenth: return [.top, .right]
        case .bottomCenterLeftSixteenth: return [.left, .top, .right]
        case .bottomCenterRightSixteenth: return [.left, .top, .right]
        case .bottomRightSixteenth: return [.left, .top]
        case .maximize: return .none
        case .leftTodo: return .right
        case .rightTodo: return .left
        }
    }
}

struct Shortcut: Codable {
    let keyCode: Int
    let modifierFlags: UInt
    
    init(_ modifierFlags: UInt, _ keyCode: Int) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
    
    init(masShortcut: MASShortcut) {
        self.keyCode = masShortcut.keyCode
        self.modifierFlags = masShortcut.modifierFlags.rawValue
    }
    
    func toMASSHortcut() -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
    }
    
    func displayString() -> String {
        let masShortcut = toMASSHortcut()
        return masShortcut.modifierFlagsString + (masShortcut.keyCodeString ?? "")
    }
}
