# Topdownapp

تطبيق آيفون أصلي (SwiftUI) لموقع Topdown: https://topdownn.pages.dev — الكود في `ios/`.

## قواعد ثابتة للتحديثات
- كل تحديث يُبنى عبر `.github/workflows/ios.yml` عند الدفع إلى `ios/**`.
- رقم الإصدار يتغيّر تلقائيًا مع كل بناء: `MARKETING_VERSION` في `ios/project.yml` هو الأساس (مثل 1.4)
  وCI يضيف رقم البناء (1.4.<run_number>)، و`CFBundleVersion` = رقم البناء. لا تُرسل نسخة بنفس رقم سابق.
- مع كل تحديث أعطِ المستخدم دائمًا:
  1. رقم الإصدار الجديد.
  2. رابط التحميل الثابت: https://github.com/Kaido1070/Topdownapp/releases/download/ios-latest/Topdown-unsigned.ipa
  3. ورابط النسخة المرقّمة: https://github.com/Kaido1070/Topdownapp/releases/download/ios-latest/Topdown-<version>-<build>.ipa
- الـIPA غير موقّع؛ المستخدم يوقّعه بنفسه.
- قبل الإرسال: تأكد أن CI نجح (ipa + simulator-smoke) وراجع لقطات المحاكي.

## الموقع
- مستودع الموقع: Kaido1070/topdown — لا تعدّل فيه إلا بطلب صريح.
- Kaido1070/Wanyapp (تطبيق Rany) مرجع أفكار فقط؛ لا تعدّل فيه.
- لا تحفظ كلمة مرور الموقع في أي ملف.
