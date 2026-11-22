#!/usr/bin/env python3
"""Fill BLEMesh/Resources/Localizable.xcstrings with Hindi (hi) translations.

Usage: python3 scripts/hindi.py [--check]
--check exits non-zero if any key lacks a Hindi translation (used by tests/CI).
Runtime labels from MeshCore (priority, category, SOS status, credibility) are added as manual keys.
"""
import json
import sys

CATALOG = "BLEMesh/Resources/Localizable.xcstrings"

HI = {
    "%@ asks: are you safe?": "%@ पूछ रहे हैं: क्या आप सुरक्षित हैं?",
    "%@ — who's safe?": "%@ — कौन सुरक्षित है?",
    "%lld": "%lld",
    "%lld hops": "%lld हॉप",
    "%lld hops away": "%lld हॉप दूर",
    "%lld messages hidden as spam — show": "%lld संदेश स्पैम मानकर छिपाए गए — दिखाएँ",
    "%lld reachable": "%lld पहुँच में",
    "%lld reports": "%lld रिपोर्ट",
    "%lld responding": "%lld मदद कर रहे हैं",
    "%lld%%": "%lld%%",
    "1 day": "1 दिन",
    "1 message hidden as spam — show": "1 संदेश स्पैम मानकर छिपाया गया — दिखाएँ",
    "1 report": "1 रिपोर्ट",
    "1 says resolved": "1 ने कहा हल हो गया",
    "30 days": "30 दिन",
    "7 days": "7 दिन",
    "90 days": "90 दिन",
    "AI": "AI",
    "AI that works offline": "बिना इंटरनेट चलने वाला AI",
    "About": "जानकारी",
    "Admin": "एडमिन",
    "Already in your language": "पहले से आपकी भाषा में है",
    "Answer from %@": "%@ से जवाब",
    "Answer questions for people nearby": "आस-पास के लोगों के सवालों के जवाब दें",
    "Area summary": "इलाके का सारांश",
    "Ask": "पूछें",
    "Ask anything — first aid, safety, translation…": "कुछ भी पूछें — प्राथमिक उपचार, सुरक्षा, अनुवाद…",
    "Ask everyone: are you safe?": "सबसे पूछें: क्या आप सुरक्षित हैं?",
    "Ask the Mesh": "मेश से पूछें",
    "Asked everyone": "सबसे पूछ लिया",
    "Asking a nearby phone…": "पास के फ़ोन से पूछ रहे हैं…",
    "Assessed by offline rules": "ऑफ़लाइन नियमों से आँका गया",
    "Assessed by on-device AI": "फ़ोन के AI से आँका गया",
    "Attach my medical ID": "मेरी मेडिकल ID जोड़ें",
    "Auto-reply to “are you safe?” after 5 min": "5 मिनट बाद “क्या आप सुरक्षित हैं?” का अपने-आप जवाब",
    "Auto-translate incoming messages": "आने वाले संदेशों का अपने-आप अनुवाद",
    "BLE Mesh": "BLE Mesh",
    "Back": "वापस",
    "Block": "ब्लॉक करें",
    "Blocked": "ब्लॉक किया गया",
    "Blocked and reported devices disappear from this phone. Their traffic is still relayed for others.":
        "ब्लॉक और रिपोर्ट किए गए डिवाइस इस फ़ोन से गायब हो जाते हैं। उनका ट्रैफ़िक दूसरों के लिए अब भी आगे भेजा जाता है।",
    "Blocked devices": "ब्लॉक किए गए डिवाइस",
    "Bluetooth LE isn't supported on this device": "इस डिवाइस पर Bluetooth LE समर्थित नहीं है",
    "Bluetooth is off": "Bluetooth बंद है",
    "Bluetooth permission needed — enable it in Settings": "Bluetooth की अनुमति चाहिए — Settings में चालू करें",
    "Can answer Ask-the-Mesh questions": "मेश से पूछे गए सवालों के जवाब दे सकता है",
    "Cancel": "रद्द करें",
    "Cancel SOS": "SOS रद्द करें",
    "Carried (store & forward)": "साथ ले जाए गए (स्टोर और फ़ॉरवर्ड)",
    "Catch me up": "जो छूट गया, बताएँ",
    "Chats": "चैट",
    "Check in": "हाल बताएँ",
    "Clear medical ID": "मेडिकल ID मिटाएँ",
    "Close": "बंद करें",
    "Collapse summary": "सारांश छोटा करें",
    "Compare these in person. If they match on both phones, nobody is impersonating either of you.":
        "इन्हें आमने-सामने मिलाएँ। दोनों फ़ोन पर एक जैसे हों तो कोई भी आप में से किसी का रूप नहीं धर रहा।",
    "Connected to %lld device(s)": "%lld डिवाइस से जुड़े हैं",
    "Contact": "संपर्क",
    "Continue": "जारी रखें",
    "Copy": "कॉपी करें",
    "Create": "बनाएँ",
    "Create a group (e.g. Family) in Chats to share check-ins privately.":
        "हाल निजी तौर पर बताने के लिए चैट में एक समूह (जैसे परिवार) बनाएँ।",
    "Decentralized Messaging": "बिना सर्वर के मैसेजिंग",
    "Delete": "हटाएँ",
    "Delivered": "पहुँच गया",
    "Demo mesh": "डेमो मेश",
    "Demo mesh (simulated devices)": "डेमो मेश (नकली डिवाइस)",
    "Describe the emergency, people involved, and landmarks": "आपातकाल, कितने लोग, और पास की पहचान वाली जगह बताएँ",
    "Details": "विवरण",
    "Direct and group messages are encrypted on your phone. Phones that relay them can't read them. Compare safety numbers to verify a contact.":
        "निजी और समूह संदेश आपके फ़ोन पर ही एन्क्रिप्ट होते हैं। उन्हें आगे भेजने वाले फ़ोन उन्हें पढ़ नहीं सकते। संपर्क की पुष्टि के लिए सुरक्षा नंबर मिलाएँ।",
    "Direct connection": "सीधा कनेक्शन",
    "Done": "हो गया",
    "Duplicates suppressed": "दोहराव रोके गए",
    "Encryption": "एन्क्रिप्शन",
    "End-to-end encrypted": "एंड-टू-एंड एन्क्रिप्टेड",
    "Erase everything (panic wipe)": "सब कुछ मिटाएँ (पैनिक वाइप)",
    "Erase everything?": "सब कुछ मिटाएँ?",
    "Erase now": "अभी मिटाएँ",
    "Expand summary": "सारांश बड़ा करें",
    "Failed": "नहीं भेजा जा सका",
    "Forever": "हमेशा",
    "GPS works without internet. Your SOS is signed but not encrypted, so anyone nearby can help — including reading your medical ID if you attach it.":
        "GPS बिना इंटरनेट के काम करता है। आपका SOS हस्ताक्षरित है पर एन्क्रिप्टेड नहीं, ताकि आस-पास कोई भी मदद कर सके — और अगर आप मेडिकल ID जोड़ते हैं तो वे उसे भी पढ़ सकते हैं।",
    "Get Started": "शुरू करें",
    "Group name": "समूह का नाम",
    "Has on-device AI": "फ़ोन में AI है",
    "Help when it matters": "ज़रूरत के समय मदद",
    "Helping others": "दूसरों की मदद",
    "Hide keyboard": "कीबोर्ड छिपाएँ",
    "Hide spam": "स्पैम छिपाएँ",
    "Hide translation": "अनुवाद छिपाएँ",
    "Hold to record a voice note": "वॉइस नोट रिकॉर्ड करने के लिए दबाए रखें",
    "How It Works": "यह कैसे काम करता है",
    "I need help": "मुझे मदद चाहिए",
    "I'm a medic (doctor, nurse, first-aider)": "मैं मेडिकल सहायक हूँ (डॉक्टर, नर्स, प्राथमिक उपचारक)",
    "I'm a rescuer / volunteer": "मैं बचावकर्मी / स्वयंसेवक हूँ",
    "I'm responding": "मैं मदद कर रहा/रही हूँ",
    "I'm safe": "मैं सुरक्षित हूँ",
    "I'm safe now": "अब मैं सुरक्षित हूँ",
    "Include my GPS location": "मेरी GPS लोकेशन जोड़ें",
    "Invalid / forged dropped": "अमान्य / जाली हटाए गए",
    "Keep messages": "संदेश रखें",
    "Keys don't match — this may be an impostor. Don't trust this contact.":
        "कुंजियाँ मेल नहीं खातीं — यह कोई धोखेबाज़ हो सकता है। इस संपर्क पर भरोसा न करें।",
    "Leave": "छोड़ें",
    "Leave group": "समूह छोड़ें",
    "Leave this group?": "यह समूह छोड़ें?",
    "Links": "कनेक्शन",
    "Location": "लोकेशन",
    "Low battery": "बैटरी कम",
    "Medical ID": "मेडिकल ID",
    "Members": "सदस्य",
    "Members (%lld)": "सदस्य (%lld)",
    "Members get the group key in an end-to-end encrypted invite. Phones that relay group messages can't read them.":
        "सदस्यों को समूह की कुंजी एंड-टू-एंड एन्क्रिप्टेड निमंत्रण में मिलती है। समूह संदेश आगे भेजने वाले फ़ोन उन्हें पढ़ नहीं सकते।",
    "Mesh (%lld reachable)": "मेश (%lld पहुँच में)",
    "Mesh ID": "मेश ID",
    "Message": "संदेश",
    "Message & SOS alerts": "संदेश और SOS अलर्ट",
    "Message everyone nearby": "आस-पास सभी को संदेश भेजें",
    "Messages find their way": "संदेश अपना रास्ता ढूँढ लेते हैं",
    "Messages hop through other phones to reach people out of range, and wait to be carried forward when someone walks into range.":
        "संदेश दूसरे फ़ोन से होकर दूर के लोगों तक पहुँचते हैं, और जब कोई पहुँच में आता है तो उसके साथ आगे बढ़ते हैं।",
    "Messaging without internet": "बिना इंटरनेट के मैसेजिंग",
    "Most important": "सबसे ज़रूरी",
    "Multi-hop & store-and-forward": "कई फ़ोन से होकर, और रुककर आगे",
    "My language": "मेरी भाषा",
    "Name": "नाम",
    "Nearby": "आस-पास",
    "Network": "नेटवर्क",
    "New Chat": "नई चैट",
    "New Group": "नया समूह",
    "New chat": "नई चैट",
    "New device": "नया डिवाइस",
    "New group": "नया समूह",
    "Next": "आगे",
    "No SOS calls nearby.": "आस-पास कोई SOS नहीं।",
    "No chats yet": "अभी कोई चैट नहीं",
    "No devices yet. Phones running BLE Mesh connect automatically when in range.":
        "अभी कोई डिवाइस नहीं। BLE Mesh वाले फ़ोन पहुँच में आते ही अपने-आप जुड़ जाते हैं।",
    "No one to add yet — people appear when they're in range.": "अभी जोड़ने के लिए कोई नहीं — लोग पहुँच में आने पर दिखेंगे।",
    "Nobody nearby yet": "अभी आस-पास कोई नहीं",
    "Not your verified “%@” — same name, different device": "आपके पुष्ट “%@” नहीं — नाम वही, डिवाइस अलग",
    "Notifications": "सूचनाएँ",
    "OK": "ठीक है",
    "On my way": "मैं आ रहा/रही हूँ",
    "On-device AI": "फ़ोन पर AI",
    "On-device triage": "फ़ोन पर प्राथमिकता जाँच",
    "Open the family locator.": "परिवार लोकेटर खोलें।",
    "Other phones running BLE Mesh appear here automatically when in range.": "BLE Mesh वाले दूसरे फ़ोन पहुँच में आने पर यहाँ अपने-आप दिखेंगे।",
    "Out of range": "पहुँच से बाहर",
    "Packets received": "मिले पैकेट",
    "Packets sent": "भेजे गए पैकेट",
    "Panic wipe deletes all messages, groups, contacts and your keys immediately, and gives this phone a new identity.":
        "पैनिक वाइप सारे संदेश, समूह, संपर्क और आपकी कुंजियाँ तुरंत मिटा देता है, और इस फ़ोन को नई पहचान देता है।",
    "Play voice note": "वॉइस नोट चलाएँ",
    "Private by design": "शुरू से ही निजी",
    "Profile": "प्रोफ़ाइल",
    "Protocol": "प्रोटोकॉल",
    "Queued": "कतार में",
    "Radio": "रेडियो",
    "Ranked by urgency using on-device triage. Treat single, unconfirmed reports with care.":
        "फ़ोन पर हुई जाँच के आधार पर तात्कालिकता के क्रम में। अकेली, अपुष्ट रिपोर्टों को सावधानी से लें।",
    "Rate-limited": "सीमा से रोके गए",
    "Reachability": "पहुँच",
    "Reachable now": "अभी पहुँच में",
    "Reaches every phone in range and is relayed onward": "पहुँच में हर फ़ोन तक जाता है और आगे भेजा जाता है",
    "Read": "पढ़ लिया",
    "Read aloud": "पढ़कर सुनाएँ",
    "Read voice notes aloud on arrival": "आते ही वॉइस नोट पढ़कर सुनाएँ",
    "Reading what you missed…": "जो छूटा उसे पढ़ रहे हैं…",
    "Relayed for others": "दूसरों के लिए आगे भेजे",
    "Remove": "हटाएँ",
    "Remove verification": "पुष्टि हटाएँ",
    "Removing someone, or anyone leaving, changes the group key so they can't read new messages.":
        "किसी को हटाने या किसी के छोड़ने पर समूह की कुंजी बदल जाती है, ताकि वे नए संदेश न पढ़ सकें।",
    "Replay introduction": "परिचय फिर से देखें",
    "Reply": "जवाब दें",
    "Report and block": "रिपोर्ट और ब्लॉक करें",
    "Report and block this device?": "इस डिवाइस को रिपोर्ट और ब्लॉक करें?",
    "Report as spam or abuse": "स्पैम या दुरुपयोग की रिपोर्ट करें",
    "Reported": "रिपोर्ट किया गया",
    "Reset": "रीसेट करें",
    "Reset all settings to defaults?": "सारी सेटिंग्स पहले जैसी कर दें?",
    "Reset settings": "सेटिंग्स रीसेट करें",
    "Resolved": "हल हो गया",
    "Retry": "फिर से भेजें",
    "Roles are shared with nearby phones so people with emergencies can find you. The auto-reply never says you're safe — only that you haven't answered, your battery, and when you were last active.":
        "भूमिकाएँ आस-पास के फ़ोन से साझा होती हैं ताकि मुसीबत में फँसे लोग आपको ढूँढ सकें। अपने-आप जवाब कभी नहीं कहता कि आप सुरक्षित हैं — बस यह कि आपने जवाब नहीं दिया, आपकी बैटरी, और आप आख़िरी बार कब सक्रिय थे।",
    "SOS": "SOS",
    "SOS board (%lld)": "SOS बोर्ड (%lld)",
    "SOS sent to everyone in range": "पहुँच में सभी को SOS भेजा गया",
    "SOS to everyone nearby": "आस-पास सभी को SOS",
    "Safety & privacy": "सुरक्षा और निजता",
    "Safety numbers (theirs, then yours)": "सुरक्षा नंबर (पहले उनका, फिर आपका)",
    "Same name as a verified contact — not them": "पुष्ट संपर्क जैसा नाम — पर वे नहीं हैं",
    "Scan their code": "उनका कोड स्कैन करें",
    "Seen before — messages wait until they're back": "पहले देखा गया — उनके लौटने तक संदेश रुके रहेंगे",
    "Send": "भेजें",
    "Send SOS": "SOS भेजें",
    "Send an SOS with your location. It's triaged on-device so responders see the most urgent requests first. Allow Bluetooth to get started.":
        "अपनी लोकेशन के साथ SOS भेजें। फ़ोन पर ही उसकी प्राथमिकता तय होती है ताकि मदद करने वाले सबसे ज़रूरी अनुरोध पहले देखें। शुरू करने के लिए Bluetooth की अनुमति दें।",
    "Sent": "भेजा गया",
    "Sent end-to-end encrypted to your groups, with your battery level.": "आपके समूहों को एंड-टू-एंड एन्क्रिप्टेड भेजा जाता है, आपकी बैटरी के स्तर के साथ।",
    "Settings": "सेटिंग्स",
    "Shows each member's latest check-in. “Unknown” means no check-in in the last 6 hours.":
        "हर सदस्य का ताज़ा हाल दिखाता है। “अज्ञात” का मतलब है पिछले 6 घंटे में कोई हाल नहीं मिला।",
    "Simulated devices: Asha, Kabir (nearby), Ravi (2 hops, has on-device AI), Meera (3 hops).":
        "नकली डिवाइस: आशा, कबीर (पास), रवि (2 हॉप, फ़ोन में AI), मीरा (3 हॉप)।",
    "Skip": "छोड़ें",
    "Something went wrong": "कुछ गड़बड़ हो गई",
    "Speak and your words travel as tiny text, read aloud on arrival. Translate on-device, get an area summary, and ask the mesh — all without the cloud.":
        "बोलिए — आपकी बात छोटे से टेक्स्ट के रूप में जाती है और पहुँचने पर पढ़कर सुनाई जाती है। फ़ोन पर अनुवाद करें, इलाके का सारांश पाएँ और मेश से पूछें — सब बिना क्लाउड के।",
    "Start a private, end-to-end encrypted chat with anyone the mesh can reach.": "मेश जिस तक पहुँच सके, उससे निजी, एंड-टू-एंड एन्क्रिप्टेड चैट शुरू करें।",
    "Starting Bluetooth…": "Bluetooth शुरू हो रहा है…",
    "Starting…": "शुरू हो रहा है…",
    "Stop": "रोकें",
    "Storage": "स्टोरेज",
    "Stored only on this phone (Keychain). Attached to an SOS only when you choose — and then anyone nearby can read it.":
        "सिर्फ़ इसी फ़ोन पर रखी जाती है (Keychain)। SOS में तभी जुड़ती है जब आप चुनें — और तब आस-पास कोई भी उसे पढ़ सकता है।",
    "Summarised on this phone (offline rules)": "इसी फ़ोन पर सारांश बना (ऑफ़लाइन नियम)",
    "Summarised on this phone by on-device AI": "इसी फ़ोन के AI ने सारांश बनाया",
    "Summarises the last hour of public messages and SOS calls nearby — on your phone, offline.":
        "आस-पास के पिछले एक घंटे के सार्वजनिक संदेशों और SOS का सारांश — आपके फ़ोन पर, ऑफ़लाइन।",
    "Tap to answer “I'm safe” or “I need help”.": "“मैं सुरक्षित हूँ” या “मुझे मदद चाहिए” कहने के लिए टैप करें।",
    "That code belongs to a different device.": "यह कोड किसी दूसरे डिवाइस का है।",
    "That isn't a BLE Mesh code.": "यह BLE Mesh कोड नहीं है।",
    "Their code": "उनका कोड",
    "Thinking…": "सोच रहे हैं…",
    "This can't be undone.": "इसे वापस नहीं किया जा सकता।",
    "This phone": "यह फ़ोन",
    "This phone hasn't met that device yet.": "यह फ़ोन अभी उस डिवाइस से नहीं मिला है।",
    "Traffic": "ट्रैफ़िक",
    "Translate": "अनुवाद करें",
    "Translate with a nearby AI phone": "पास के AI वाले फ़ोन से अनुवाद कराएँ",
    "Translation unavailable for this language pair": "इन भाषाओं के बीच अनुवाद उपलब्ध नहीं",
    "Try asking": "पूछकर देखें",
    "Unblock": "अनब्लॉक करें",
    "Verified": "पुष्ट",
    "Verified in person": "आमने-सामने पुष्टि की गई",
    "Verified — show codes": "पुष्ट — कोड दिखाएँ",
    "Verified — this really is %@": "पुष्ट — यह सच में %@ हैं",
    "Verify": "पुष्टि करें",
    "Verify %@": "%@ की पुष्टि करें",
    "Verify with QR code": "QR कोड से पुष्टि करें",
    "Version": "वर्ज़न",
    "Voice note · %llds": "वॉइस नोट · %lld सेकंड",
    "Voice, translation, SOS triage": "आवाज़, अनुवाद, SOS प्राथमिकता",
    "Waiting for an answer from the mesh…": "मेश से जवाब का इंतज़ार…",
    "Walk back into range": "वापस पहुँच में आएँ",
    "Walk out of range": "पहुँच से बाहर जाएँ",
    "Welcome to BLE Mesh": "BLE Mesh में आपका स्वागत है",
    "What's happening?": "क्या हो रहा है?",
    "Who's safe? (family locator)": "कौन सुरक्षित है? (परिवार लोकेटर)",
    "You answered": "आपने जवाब दिया",
    "You haven't blocked anyone.": "आपने किसी को ब्लॉक नहीं किया है।",
    "Your code — let them scan it": "आपका कोड — उन्हें स्कैन करने दें",
    "Your name": "आपका नाम",
    "Your phone talks directly to nearby phones over Bluetooth and passes messages along for others. No SIM, Wi-Fi, account or server needed.":
        "आपका फ़ोन Bluetooth से सीधे पास के फ़ोन से बात करता है और दूसरों के संदेश आगे पहुँचाता है। न SIM, न Wi-Fi, न अकाउंट, न सर्वर चाहिए।",
    "Your safety number": "आपका सुरक्षा नंबर",
    "Your verification code": "आपका पुष्टि कोड",
    "direct": "सीधा",
    "e.g. Family, Rescue team": "जैसे परिवार, बचाव दल",
    "offline": "ऑफ़लाइन",
    "· %lld hops": "· %lld हॉप",
    "· %lld people": "· %lld लोग",
    "“%@”": "“%@”",
    "": "",
    "List": "सूची",
    "Map": "नक्शा",
    "View": "दृश्य",
    "You": "आप",
    "Your SOS": "आपका SOS",
    "No SOS calls with a location yet.": "अभी किसी SOS में लोकेशन नहीं है।",
    "Map tiles need internet. Pins, distances and directions work offline.": "नक्शे की तस्वीरों के लिए इंटरनेट चाहिए। पिन, दूरी और दिशा बिना इंटरनेट काम करते हैं।",
    "Distance and direction: %@": "दूरी और दिशा: %@",
    " · %@": " · %@",
    "…or paste their code": "…या उनका कोड पेस्ट करें",
    "⚠️ %@ needs help": "⚠️ %@ को मदद चाहिए",
    "🆘 %@%@ SOS from %@": "🆘 %1$@%3$@ से %2$@ SOS",
    "🔋 %lld%%": "🔋 %lld%%",
    "🧰 You're a responder nearby — ": "🧰 आप पास के मददगार हैं — ",
    "🩺 You're a medic nearby — ": "🩺 आप पास के मेडिकल सहायक हैं — ",
}

# Runtime labels from MeshCore, looked up with L(_:).
MANUAL = {
    "Low": "कम", "Medium": "मध्यम", "High": "ऊँची", "Critical": "गंभीर",
    "Medical": "चिकित्सा", "Fire": "आग", "Flood": "बाढ़", "Trapped": "फँसे हुए", "Violence": "हिंसा",
    "Missing person": "लापता व्यक्ति", "Supplies": "सामान", "Other": "अन्य",
    "Open": "खुला", "Acknowledged": "देख लिया गया", "Help on the way": "मदद आ रही है", "Cancelled": "रद्द",
    "Confirmed by several people": "कई लोगों ने पुष्टि की", "Unverified — single report": "अपुष्ट — एक ही रिपोर्ट",
    "Disputed": "विवादित",
    "here": "यहीं",
    "N": "उत्तर", "NE": "उत्तर-पूर्व", "E": "पूर्व", "SE": "दक्षिण-पूर्व",
    "S": "दक्षिण", "SW": "दक्षिण-पश्चिम", "W": "पश्चिम", "NW": "उत्तर-पश्चिम",
}


def main() -> int:
    with open(CATALOG, encoding="utf-8") as f:
        catalog = json.load(f)
    strings = catalog["strings"]
    for key in MANUAL:
        strings.setdefault(key, {"extractionState": "manual"})
    table = {**HI, **MANUAL}
    missing = []
    for key, entry in strings.items():
        value = table.get(key)
        if value is None:
            missing.append(key)
            continue
        entry.setdefault("localizations", {})["hi"] = {"stringUnit": {"state": "translated", "value": value}}
    if "--check" in sys.argv:
        for key in missing:
            print("missing Hindi:", repr(key))
        return 1 if missing else 0
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    for key in missing:
        print("missing Hindi:", repr(key))
    print(f"{len(strings) - len(missing)}/{len(strings)} translated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
