# iPhone �� iPad IPA ����

�����̻�ʹ�� Apple ����ʵ�豸���������� arm64 App���ٴ��Ϊ IPA��ͬһ�� App ͬʱ���� iPhone �� iPad ֧�֣�iOS / iPadOS 26 ʹ�� Liquid Glass���Ͼ�ϵͳʹ�ô����еļ�����ۡ����ϵͳ���� iOS / iPadOS 17��

iPad ��ǿ��ȫ��������ȫ���ĸ�������֧��ϵͳ��������ɱ䴰�ڡ������еķ���ʹ�С�� iPadOS �Ĺ���Ϊ׼���Ķ�����ƫ�ò��ܸ���ϵͳ�Դ��ڳ��������ơ�

��ǰԴ��Ϊ **0.4.0��build 4��**������ɱ��ع��̼� Swift �﷨��飻��δ���б��汾�� Mac ���롢XCTest �� IPA ���ɡ�������Ӧ�˶԰汾 0.4.0��build 4��������Ϊ Komiic-0.4.0-iPhone-iPad-unsigned.ipa�����ܰѾɰ�������Ϊ�°汾��

����Ϊ **3.0 ��ʷ������¼**����ʱ����ɱ��ؾ�̬��飬���ϴ��� [`codex/komiic-3.0`](https://github.com/hahahalucas/Komiic/tree/codex/komiic-3.0) ������֧���ύ [`9e9e97414bfaf017e0658f565c748a3b018d40c7`](https://github.com/hahahalucas/Komiic/commit/9e9e97414bfaf017e0658f565c748a3b018d40c7)��[Mac �ƶ˹��� 44999974479](https://github.com/hahahalucas/Komiic/actions/runs/44999974479)���������豸���롢�����豸�� 36 �� XCTest �� IPA �Դ��������ǰ��������֤�� 3.0 �����������ɺ�Ӧ�˶԰��ڰ汾�� build��������Ϊ `Komiic-3.0-iPhone-iPad-unsigned.ipa`�����ܽ��ɰ�������Ϊ�°汾������

����Ϊ **2.0 ��ʷ������¼**��2.0 ���� [Mac �ƶ��豸������](https://github.com/hahahalucas/Komiic/actions/runs/44991028791)����ɱ��룬��Ŀ��Ŀ¼�ѱ��潻������ `Komiic-2.0-iPhone-iPad-unsigned.ipa`���汾 2.0��build 2��822,136 �ֽڣ���[��������](https://github.com/hahahalucas/Komiic/actions/runs/44991028791/artifacts/14742335404)�ڵ� IPA ʹ��Ĭ���ļ��������غ�����Ϊ���汾�ŵĽ����ļ����豸������ʹ�� `--skip-tests`��Xcode 26.6 / iOS SDK 26.5 �������ƶˡ����� IPA У���ͨ����

ͬһ App Դ���[������������](https://github.com/hahahalucas/Komiic/actions/runs/44989974389)Ҳ�ѳɹ���iPhone �� iPad �� 18 �����ͨ������ʧ�ܣ���������ģ������ͼ������豸����롣[������֤����](https://github.com/hahahalucas/Komiic/actions/runs/44989974389/artifacts/14742196424)�������Խ������ͼ����־������֤��λ��Ϊ `build/verified-artifacts-2.0/`�������������������豸���������ι����� App Դ����ȫһ�£��������������е�����δʹ���û�֤�飬��װǰ��Ҫ����ǩ����ʵ�ʻ��������������װ��δ���ա�Դ�롢�����ύ�� SHA-256 ��[��֤��¼](Verification.md)����Ŀ¼ԭ�е��ް汾�� IPA �� 0.1.0 ��ʷ����

## ����밲װ

- Ĭ������ `Komiic-iPhone-iPad-unsigned.ipa`����������ʵ iOS �豸��ִ�д��룬**û�� Apple ��װǩ��������ֱ�Ӱ�װ**���û���Ҫʹ���Լ��ĺϷ�֤��Ͷ�Ӧ�豸�����ļ����ǩ����
- ��ѡǩ���������� `Komiic-iPhone-iPad-signed.ipa`�������ṩ���е���ʵ Apple ֤�顢����������ļ�����װ��Χ����Щ���Ͼ�����Ad Hoc / ���������ļ���Ҫ����Ŀ�� iPhone �� iPad ���豸��ʶ��
- �����̲�����֤�顢��ע���豸�����ϴ� App Store��Ҳ���� App Store �����ļ����Ϊ��ֱ�Ӱ�װ�İ汾��

## �� Mac ������

��Ҫ���� Xcode 26+��iOS SDK 26+���Լ��Ѿ���װ�� iOS 26+ iPhone �� iPad ģ����������ͨ�� `DEVELOPER_DIR` ѡ�� Xcode��

```sh
bash scripts/build_ipa.sh --unsigned
```

�ű�������֤���̡��� iPhone/iPad ģ����ִ�� XCTest���˳������������������� App ����ͼ���ٹ����豸 Release �汾������ͼ�� IPA�����Ŀ¼Ϊ���ζ����� `build/ipa.XXXXXX/artifacts/`������ IPA��SHA-256����鱨�桢���Խ������ͼ��������־��

������֤���Ĺ��������п�����ȷ�����ظ���ģ�������ԣ�

```sh
bash scripts/build_ipa.sh --unsigned --skip-tests
```

��ѡ���������ʵ�豸����� IPA ��飬Ҳ�������ɽ�ͼ��û�� Xcode 26+ ʱ�ű�ֱ��ʧ�ܡ�

## GitHub �ƶ˹���

��׼�� `.github/workflows/build-ipa.yml`��֧���ֶ����У������͵� `main`��`komiic-ios-build` ��֧ʱ�Զ����С�

�����ֿ��ַΪ [hahahalucas/Komiic](https://github.com/hahahalucas/Komiic)���� `main` ���ʹ������Զ���ʼ�Ʊ��룬Ҳ���ԴӲֿ� **Actions �� Build iPhone and iPad IPA �� Run workflow** �ֶ����С�Ĭ��ѡ�� `unsigned`�������ɹ���������ҵ�� Artifact��Ĭ�ϲ���ʹ��ǩ�����ϻ򷢲� Release��Artifact ���� 7 �졣

������ʹ�� GitHub �ı�׼ `macos-26` runner��2026-11-19 ���ĵ�[�ٷ������嵥](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)�г� Xcode 26.6 ΪĬ�ϰ汾��[�ٷ� runner �ĵ�](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)�г��ñ�ǩ���������£���˽ű��Ի���֤ʵ�� Xcode �� SDK �汾�������ֿ�ʹ�ñ�׼ GitHub �й� runner �ļ��������ѣ����ܲ�������������ʱ���ʹ洢���ƣ���� [GitHub Actions ����˵��](https://docs.github.com/en/actions/concepts/billing-and-usage)��˽�вֿ��ִ��ʹ���˻��� Actions ��ȣ��������ְ� GitHub ���˻����üƷѡ�

## ��ѡǩ������

ֻ���Ѿ�ӵ��ǩ������ʱ��ѡ�� `signed`���ڲֿ� Actions Secrets ���ã�

| Secret | ���� |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | ���� Apple ǩ��֤����˽Կ������ p12������ Base64 ���� |
| `IOS_CERTIFICATE_PASSWORD` | �� p12 ������ |
| `IOS_PROVISIONING_PROFILE_BASE64` | ��Ӧ������Ad Hoc ����ҵ�����ļ��� Base64 ���� |

����ʱ�� `bundle_id` ��Ϊ�����ļ������� App Bundle Identifier���ű���˶������ļ�����Ч�ڡ�App ��ʶ��ֱ�Ӱ�װ��ʽ��ȱ�����ϻ�ƥ��ʱʧ�ܣ����ᾲĬ��Ϊ unsigned��

Mac ����Ҳ֧��ͬ�������������Լ� `KOMIIC_BUNDLE_ID`��Ȼ��ִ�� `bash scripts/build_ipa.sh --signed`����Ҫ����Щֵд��ֿ��ļ��������¼�򹫿���־���ű�ʹ����ʱԿ�״�������ʱ�ָ�ԭԿ�״������б���������ʱ֤�鼰���ΰ�װ�������ļ�������ɾ����ǰ�Ѵ��ڵ�ͬһ�����ļ���

## IPA ���ķ�Χ

```sh
python3 scripts/verify_ipa.py path/to/Komiic-iPhone-iPad-unsigned.ipa --expected-signing unsigned
```

��������

- ZIP �ṹ��Ψһ App��Info.plist����ִ���ļ�Ȩ�ޡ�
- `UIDeviceFamily` ͬʱ���� iPhone �� iPad��֧��ƽ̨Ϊ `iPhoneOS`��
- ��ʵ 64 λ arm64 Mach-O ��ִ���ļ���ƽ̨Ϊ iOS �豸������ģ������ macOS��
- Mach-O �� Info.plist �� SDK ��Ϊ iOS 26+������ SwiftUI ��̬���ӣ������þ���Ƽ��ݿ��ء�
- unsigned / signed ��ǩ���ṹ�������ļ�״̬һ�£�����¼�ļ�ɢ�С�

Python ��鲻��֤�� Apple ��������Ч��Ҳ����֤�����н��潻��������ǩ������������ Mac ��ִ�� `codesign --verify --deep --strict`�������Ƿ�ɰ�װ�����豸�������ļ���Ȩ������Liquid Glass �Ӿ�������ʵ iOS 26 ��ͼ���豸�������ա�

��������ڲ��ع�������� Windows ִ�У�

```sh
python scripts/verify_ipa.py --self-test
```

��Щ����ֻ���ڴ��й���ṹ��������֤�ܾ��߼�������д���򽻸�ʾ�� IPA��
