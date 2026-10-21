# Lossless mechanical transcription of the existing MPFR-certified strip data.
# Verified against the frozen table digest by the Bend sampler tests.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed

type Strip is Data:
	Strip{x: Fixed.Fixed, y: Fixed.Fixed, k: Core.Wide}

def lookup_0_1(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2099572192, 1466304710}, 1}, Fixed.Fixed{Core.Wide{0, 0}, 0}, Core.Wide{7838188, 19888938}}

def lookup_1_2(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1961808392, 649382856}, 1}, Fixed.Fixed{Core.Wide{1385699034, 3889968248}, 4294967286}, Core.Wide{7918290, 1503191631}}

def lookup_0_2(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 1), u => lookup_0_1(index), u => lookup_1_2(index))

def lookup_2_3(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1851817185, 3824599203}, 1}, Fixed.Fixed{Core.Wide{1434352911, 113360391}, 4294967287}, Core.Wide{8074799, 3212935522}}

def lookup_3_4(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1782542818, 1373463486}, 1}, Fixed.Fixed{Core.Wide{1109949454, 3267892603}, 4294967288}, Core.Wide{8146898, 1159786463}}

def lookup_2_4(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 3), u => lookup_2_3(index), u => lookup_3_4(index))

def lookup_0_4(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 2), u => lookup_0_2(index), u => lookup_2_4(index))

def lookup_4_5(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1731180549, 22981105}, 1}, Fixed.Fixed{Core.Wide{1517986660, 853642797}, 4294967288}, Core.Wide{8189112, 4027198651}}

def lookup_5_6(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1690010193, 3172095634}, 1}, Fixed.Fixed{Core.Wide{1938129891, 2980114695}, 4294967288}, Core.Wide{8217090, 3243328412}}

def lookup_4_6(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 5), u => lookup_4_5(index), u => lookup_5_6(index))

def lookup_6_7(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1655455486, 2851098219}, 1}, Fixed.Fixed{Core.Wide{1184254118, 1421759691}, 4294967289}, Core.Wide{8237110, 537043357}}

def lookup_7_8(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1625558036, 2814954935}, 1}, Fixed.Fixed{Core.Wide{1403934984, 1799330963}, 4294967289}, Core.Wide{8252204, 235258318}}

def lookup_6_8(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 7), u => lookup_6_7(index), u => lookup_7_8(index))

def lookup_4_8(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 6), u => lookup_4_6(index), u => lookup_6_8(index))

def lookup_0_8(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 4), u => lookup_0_4(index), u => lookup_4_8(index))

def lookup_8_9(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1599125459, 1530539051}, 1}, Fixed.Fixed{Core.Wide{1627656246, 915535587}, 4294967289}, Core.Wide{8264025, 2029066087}}

def lookup_9_10(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1575376216, 605669308}, 1}, Fixed.Fixed{Core.Wide{1855075485, 1044303201}, 4294967289}, Core.Wide{8273555, 1986619669}}

def lookup_8_10(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 9), u => lookup_8_9(index), u => lookup_9_10(index))

def lookup_10_11(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1553769409, 2112408768}, 1}, Fixed.Fixed{Core.Wide{2085923133, 3413462250}, 4294967289}, Core.Wide{8281414, 3270544780}}

def lookup_11_12(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1533914676, 663274553}, 1}, Fixed.Fixed{Core.Wide{1159990481, 2160092831}, 4294967290}, Core.Wide{8288016, 598801653}}

def lookup_10_12(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 11), u => lookup_10_11(index), u => lookup_11_12(index))

def lookup_8_12(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 10), u => lookup_8_10(index), u => lookup_10_12(index))

def lookup_12_13(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1515520762, 2140604439}, 1}, Fixed.Fixed{Core.Wide{1278534198, 2910349024}, 4294967290}, Core.Wide{8293645, 1034304865}}

def lookup_13_14(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1498364396, 28026420}, 1}, Fixed.Fixed{Core.Wide{1398516683, 4005665711}, 4294967290}, Core.Wide{8298506, 1326940302}}

def lookup_12_14(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 13), u => lookup_12_13(index), u => lookup_13_14(index))

def lookup_14_15(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1482270526, 410594609}, 1}, Fixed.Fixed{Core.Wide{1519872976, 788404800}, 4294967290}, Core.Wide{8302749, 1844127834}}

def lookup_15_16(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1467099280, 3947100110}, 1}, Fixed.Fixed{Core.Wide{1642546904, 50605249}, 4294967290}, Core.Wide{8306487, 2051438624}}

def lookup_14_16(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 15), u => lookup_14_15(index), u => lookup_15_16(index))

def lookup_12_16(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 14), u => lookup_12_14(index), u => lookup_14_16(index))

def lookup_8_16(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 12), u => lookup_8_12(index), u => lookup_12_16(index))

def lookup_0_16(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 8), u => lookup_0_8(index), u => lookup_8_16(index))

def lookup_16_17(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1452737069, 3325519299}, 1}, Fixed.Fixed{Core.Wide{1766489400, 2343555559}, 4294967290}, Core.Wide{8309807, 227922856}}

def lookup_17_18(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1439090341, 730885962}, 1}, Fixed.Fixed{Core.Wide{1891657231, 874792542}, 4294967290}, Core.Wide{8312775, 3245347862}}

def lookup_16_18(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 17), u => lookup_16_17(index), u => lookup_17_18(index))

def lookup_18_19(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1426081096, 3925413035}, 1}, Fixed.Fixed{Core.Wide{2018012014, 171024991}, 4294967290}, Core.Wide{8315447, 692975767}}

def lookup_19_20(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1413643599, 2796619972}, 1}, Fixed.Fixed{Core.Wide{2145519452, 1654051997}, 4294967290}, Core.Wide{8317864, 1311891432}}

def lookup_18_20(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 19), u => lookup_18_19(index), u => lookup_19_20(index))

def lookup_16_20(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 18), u => lookup_16_18(index), u => lookup_18_20(index))

def lookup_20_21(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1401721911, 908332439}, 1}, Fixed.Fixed{Core.Wide{1137074362, 1509958644}, 4294967291}, Core.Wide{8320062, 737670480}}

def lookup_21_22(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1390268021, 2909315204}, 1}, Fixed.Fixed{Core.Wide{1201935996, 2108348685}, 4294967291}, Core.Wide{8322069, 2170260816}}

def lookup_20_22(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 21), u => lookup_20_21(index), u => lookup_21_22(index))

def lookup_22_23(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1379240406, 1896804947}, 1}, Fixed.Fixed{Core.Wide{1267332000, 4157755959}, 4294967291}, Core.Wide{8323910, 661863803}}

def lookup_23_24(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1368602898, 2632472220}, 1}, Fixed.Fixed{Core.Wide{1333250874, 1673206309}, 4294967291}, Core.Wide{8325604, 331618466}}

def lookup_22_24(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 23), u => lookup_22_23(index), u => lookup_23_24(index))

def lookup_20_24(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 22), u => lookup_20_22(index), u => lookup_22_24(index))

def lookup_16_24(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 20), u => lookup_16_20(index), u => lookup_20_24(index))

def lookup_24_25(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1358323797, 1366970612}, 1}, Fixed.Fixed{Core.Wide{1399682104, 1151168610}, 4294967291}, Core.Wide{8327168, 483044024}}

def lookup_25_26(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1348375154, 3885460012}, 1}, Fixed.Fixed{Core.Wide{1466616051, 3401007986}, 4294967291}, Core.Wide{8328616, 2441029609}}

def lookup_24_26(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 25), u => lookup_24_25(index), u => lookup_25_26(index))

def lookup_26_27(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1338732201, 2211566783}, 1}, Fixed.Fixed{Core.Wide{1534043854, 1665238931}, 4294967291}, Core.Wide{8329961, 2943716572}}

def lookup_27_28(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1329372876, 1544722570}, 1}, Fixed.Fixed{Core.Wide{1601957342, 3164369201}, 4294967291}, Core.Wide{8331213, 4293456314}}

def lookup_26_28(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 27), u => lookup_26_27(index), u => lookup_27_28(index))

def lookup_24_28(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 26), u => lookup_24_26(index), u => lookup_26_28(index))

def lookup_28_29(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1320277442, 3122915756}, 1}, Fixed.Fixed{Core.Wide{1670348969, 2731975240}, 4294967291}, Core.Wide{8332382, 2713166526}}

def lookup_29_30(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1311428169, 1493444909}, 1}, Fixed.Fixed{Core.Wide{1739211748, 2773844639}, 4294967291}, Core.Wide{8333475, 2226885633}}

def lookup_28_30(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 29), u => lookup_28_29(index), u => lookup_29_30(index))

def lookup_30_31(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1302809064, 3466658037}, 1}, Fixed.Fixed{Core.Wide{1808539200, 3783113917}, 4294967291}, Core.Wide{8334499, 2580003345}}

def lookup_31_32(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1294405654, 3091893266}, 1}, Fixed.Fixed{Core.Wide{1878325308, 2695409802}, 4294967291}, Core.Wide{8335460, 4190209006}}

def lookup_30_32(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 31), u => lookup_30_31(index), u => lookup_31_32(index))

def lookup_28_32(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 30), u => lookup_28_30(index), u => lookup_30_32(index))

def lookup_24_32(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 28), u => lookup_24_28(index), u => lookup_28_32(index))

def lookup_16_32(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 24), u => lookup_16_24(index), u => lookup_24_32(index))

def lookup_0_32(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 16), u => lookup_0_16(index), u => lookup_16_32(index))

def lookup_32_33(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1286204793, 2727512886}, 1}, Fixed.Fixed{Core.Wide{1948564474, 3083176238}, 4294967291}, Core.Wide{8336365, 95772356}}

def lookup_33_34(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1278194505, 1522251384}, 1}, Fixed.Fixed{Core.Wide{2019251486, 3376812598}, 4294967291}, Core.Wide{8337216, 2169835535}}

def lookup_32_34(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 33), u => lookup_32_33(index), u => lookup_33_34(index))

def lookup_34_35(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1270363846, 2783171869}, 1}, Fixed.Fixed{Core.Wide{2090381485, 2981678589}, 4294967291}, Core.Wide{8338019, 2835043625}}

def lookup_35_36(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1262702790, 1533959673}, 1}, Fixed.Fixed{Core.Wide{1080974968, 3281147510}, 4294967292}, Core.Wide{8338778, 1142005242}}

def lookup_34_36(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 35), u => lookup_34_35(index), u => lookup_35_36(index))

def lookup_32_36(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 34), u => lookup_32_34(index), u => lookup_34_36(index))

def lookup_36_37(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1255202124, 2821278250}, 1}, Fixed.Fixed{Core.Wide{1116976304, 1448642429}, 4294967292}, Core.Wide{8339495, 3028634109}}

def lookup_37_38(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1247853365, 3694780492}, 1}, Fixed.Fixed{Core.Wide{1153192771, 3361633262}, 4294967292}, Core.Wide{8340175, 64327505}}

def lookup_36_38(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 37), u => lookup_36_37(index), u => lookup_37_38(index))

def lookup_38_39(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1240648682, 2707732086}, 1}, Fixed.Fixed{Core.Wide{1189622522, 1579547005}, 4294967292}, Core.Wide{8340818, 3995551537}}

def lookup_39_40(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1233580829, 3647176866}, 1}, Fixed.Fixed{Core.Wide{1226263827, 1949711741}, 4294967292}, Core.Wide{8341429, 3954585266}}

def lookup_38_40(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 39), u => lookup_38_39(index), u => lookup_39_40(index))

def lookup_36_40(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 38), u => lookup_36_38(index), u => lookup_38_40(index))

def lookup_32_40(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 36), u => lookup_32_36(index), u => lookup_36_40(index))

def lookup_40_41(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1226643090, 2993721798}, 1}, Fixed.Fixed{Core.Wide{1263115070, 1824798000}, 4294967292}, Core.Wide{8342010, 954874180}}

def lookup_41_42(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1219829225, 3209673979}, 1}, Fixed.Fixed{Core.Wide{1300174739, 1694082060}, 4294967292}, Core.Wide{8342561, 3712630041}}

def lookup_40_42(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 41), u => lookup_40_41(index), u => lookup_41_42(index))

def lookup_42_43(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1213133428, 322045927}, 1}, Fixed.Fixed{Core.Wide{1337441420, 2590639145}, 4294967292}, Core.Wide{8343086, 2977608146}}

def lookup_43_44(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1206550283, 2338587879}, 1}, Fixed.Fixed{Core.Wide{1374913792, 1820871136}, 4294967292}, Core.Wide{8343586, 1684983733}}

def lookup_42_44(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 43), u => lookup_42_43(index), u => lookup_43_44(index))

def lookup_40_44(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 42), u => lookup_40_42(index), u => lookup_42_44(index))

def lookup_44_45(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1200074735, 2461590939}, 1}, Fixed.Fixed{Core.Wide{1412590619, 3903761766}, 4294967292}, Core.Wide{8344062, 2146148139}}

def lookup_45_46(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1193702053, 3332002712}, 1}, Fixed.Fixed{Core.Wide{1450470749, 3516560574}, 4294967292}, Core.Wide{8344516, 1819744566}}

def lookup_44_46(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 45), u => lookup_44_45(index), u => lookup_45_46(index))

def lookup_46_47(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1187427805, 4240325970}, 1}, Fixed.Fixed{Core.Wide{1488553106, 355746088}, 4294967292}, Core.Wide{8344949, 1959334582}}

def lookup_47_48(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1181247833, 1001304989}, 1}, Fixed.Fixed{Core.Wide{1526836685, 2770933348}, 4294967292}, Core.Wide{8345362, 3369080647}}

def lookup_46_48(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 47), u => lookup_46_47(index), u => lookup_47_48(index))

def lookup_44_48(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 46), u => lookup_44_46(index), u => lookup_46_48(index))

def lookup_40_48(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 44), u => lookup_40_44(index), u => lookup_44_48(index))

def lookup_32_48(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 40), u => lookup_32_40(index), u => lookup_40_48(index))

def lookup_48_49(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1175158227, 1212778570}, 1}, Fixed.Fixed{Core.Wide{1565320554, 2823140750}, 4294967292}, Core.Wide{8345757, 2153343578}}

def lookup_49_50(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1169155310, 2008797794}, 1}, Fixed.Fixed{Core.Wide{1604003844, 4223610531}, 4294967292}, Core.Wide{8346134, 2640903408}}

def lookup_48_50(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 49), u => lookup_48_49(index), u => lookup_49_50(index))

def lookup_50_51(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1163235617, 2159604519}, 1}, Fixed.Fixed{Core.Wide{1642885750, 4238415466}, 4294967292}, Core.Wide{8346495, 239872533}}

def lookup_51_52(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1157395879, 270908380}, 1}, Fixed.Fixed{Core.Wide{1681965526, 2458024611}, 4294967292}, Core.Wide{8346839, 2943379169}}

def lookup_50_52(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 51), u => lookup_50_51(index), u => lookup_51_52(index))

def lookup_48_52(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 50), u => lookup_48_50(index), u => lookup_50_52(index))

def lookup_52_53(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1151633006, 3983858805}, 1}, Fixed.Fixed{Core.Wide{1721242482, 1970023017}, 4294967292}, Core.Wide{8347169, 1292219529}}

def lookup_53_54(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1145944080, 2176912135}, 1}, Fixed.Fixed{Core.Wide{1760715983, 2844387849}, 4294967292}, Core.Wide{8347484, 2759032452}}

def lookup_52_54(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 53), u => lookup_52_53(index), u => lookup_53_54(index))

def lookup_54_55(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1140326334, 2592005954}, 1}, Fixed.Fixed{Core.Wide{1800385447, 735616303}, 4294967292}, Core.Wide{8347786, 1705351589}}

def lookup_55_56(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1134777148, 1167479132}, 1}, Fixed.Fixed{Core.Wide{1840250339, 3414728532}, 4294967292}, Core.Wide{8348075, 875973390}}

def lookup_54_56(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 55), u => lookup_54_55(index), u => lookup_55_56(index))

def lookup_52_56(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 54), u => lookup_52_54(index), u => lookup_54_56(index))

def lookup_48_56(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 52), u => lookup_48_52(index), u => lookup_52_56(index))

def lookup_56_57(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1129294034, 2834613953}, 1}, Fixed.Fixed{Core.Wide{1880310176, 742402286}, 4294967292}, Core.Wide{8348351, 2826538990}}

def lookup_57_58(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1123874631, 3142656871}, 1}, Fixed.Fixed{Core.Wide{1920564516, 3989836156}, 4294967292}, Core.Wide{8348616, 1349340098}}

def lookup_56_58(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 57), u => lookup_56_57(index), u => lookup_57_58(index))

def lookup_58_59(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1118516693, 3338867737}, 1}, Fixed.Fixed{Core.Wide{1961012966, 4131876614}, 4294967292}, Core.Wide{8348869, 2962327044}}

def lookup_59_60(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1113218083, 2726908675}, 1}, Fixed.Fixed{Core.Wide{2001655173, 3684838461}, 4294967292}, Core.Wide{8349112, 1152087456}}

def lookup_58_60(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 59), u => lookup_58_59(index), u => lookup_59_60(index))

def lookup_56_60(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 58), u => lookup_56_58(index), u => lookup_58_60(index))

def lookup_60_61(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1107976765, 2360892947}, 1}, Fixed.Fixed{Core.Wide{2042490826, 1788155670}, 4294967292}, Core.Wide{8349344, 2155199936}}

def lookup_61_62(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1102790798, 2627314278}, 1}, Fixed.Fixed{Core.Wide{2083519653, 1211651649}, 4294967292}, Core.Wide{8349566, 3493851547}}

def lookup_60_62(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 61), u => lookup_60_61(index), u => lookup_61_62(index))

def lookup_62_63(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1097658330, 3066951925}, 1}, Fixed.Fixed{Core.Wide{2124741421, 2894637869}, 4294967292}, Core.Wide{8349779, 2575249948}}

def lookup_63_64(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1092577592, 4225178967}, 1}, Fixed.Fixed{Core.Wide{1083077968, 435463365}, 4294967293}, Core.Wide{8349983, 995196601}}

def lookup_62_64(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 63), u => lookup_62_63(index), u => lookup_63_64(index))

def lookup_60_64(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 62), u => lookup_60_62(index), u => lookup_62_64(index))

def lookup_56_64(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 60), u => lookup_56_60(index), u => lookup_60_64(index))

def lookup_48_64(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 56), u => lookup_48_56(index), u => lookup_56_64(index))

def lookup_32_64(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 48), u => lookup_32_48(index), u => lookup_48_64(index))

def lookup_0_64(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 32), u => lookup_0_32(index), u => lookup_32_64(index))

def lookup_64_65(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1087546894, 2752162990}, 1}, Fixed.Fixed{Core.Wide{1103881518, 3808300854}, 4294967293}, Core.Wide{8350178, 250945810}}

def lookup_65_66(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1082564618, 1059396815}, 1}, Fixed.Fixed{Core.Wide{1124781301, 1210508152}, 4294967293}, Core.Wide{8350364, 1748332539}}

def lookup_64_66(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 65), u => lookup_64_65(index), u => lookup_65_66(index))

def lookup_66_67(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1077629215, 1317131375}, 1}, Fixed.Fixed{Core.Wide{1145777270, 2310725838}, 4294967293}, Core.Wide{8350542, 2513305943}}

def lookup_67_68(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2145478404, 1675111571}, 0}, Fixed.Fixed{Core.Wide{1166869398, 2696251690}, 4294967293}, Core.Wide{8350712, 3787801010}}

def lookup_66_68(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 67), u => lookup_66_67(index), u => lookup_67_68(index))

def lookup_64_68(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 66), u => lookup_64_66(index), u => lookup_66_68(index))

def lookup_68_69(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2135786312, 3214808381}, 0}, Fixed.Fixed{Core.Wide{1188057673, 3589604947}, 4294967293}, Core.Wide{8350875, 2445233253}}

def lookup_69_70(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2126179425, 3297442659}, 0}, Fixed.Fixed{Core.Wide{1209342100, 1626394726}, 4294967293}, Core.Wide{8351030, 3880371786}}

def lookup_68_70(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 69), u => lookup_68_69(index), u => lookup_69_70(index))

def lookup_70_71(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2116655122, 643696893}, 0}, Fixed.Fixed{Core.Wide{1230722698, 226154409}, 4294967293}, Core.Wide{8351179, 539060125}}

def lookup_71_72(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2107210883, 604348468}, 0}, Fixed.Fixed{Core.Wide{1252199501, 3894176629}, 4294967293}, Core.Wide{8351320, 1987169945}}

def lookup_70_72(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 71), u => lookup_70_71(index), u => lookup_71_72(index))

def lookup_68_72(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 70), u => lookup_68_70(index), u => lookup_70_72(index))

def lookup_64_72(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 68), u => lookup_64_68(index), u => lookup_68_72(index))

def lookup_72_73(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2097844286, 3711284417}, 0}, Fixed.Fixed{Core.Wide{1273772561, 4037644934}, 4294967293}, Core.Wide{8351455, 554705899}}

def lookup_73_74(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2088553003, 156009082}, 0}, Fixed.Fixed{Core.Wide{1295441942, 3534627497}, 4294967293}, Core.Wide{8351583, 1404111714}}

def lookup_72_74(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 73), u => lookup_72_73(index), u => lookup_73_74(index))

def lookup_74_75(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2079334788, 129147959}, 0}, Fixed.Fixed{Core.Wide{1317207723, 2740958814}, 4294967293}, Core.Wide{8351705, 1058688604}}

def lookup_75_76(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2070187480, 1117578802}, 0}, Fixed.Fixed{Core.Wide{1339069997, 2764487748}, 4294967293}, Core.Wide{8351821, 290497080}}

def lookup_74_76(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 75), u => lookup_74_75(index), u => lookup_75_76(index))

def lookup_72_76(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 74), u => lookup_72_74(index), u => lookup_74_76(index))

def lookup_76_77(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2061108995, 3720093441}, 0}, Fixed.Fixed{Core.Wide{1361028872, 232216786}, 4294967293}, Core.Wide{8351930, 4123124430}}

def lookup_77_78(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2052097324, 2868651083}, 0}, Fixed.Fixed{Core.Wide{1383084467, 3610820558}, 4294967293}, Core.Wide{8352035, 359403557}}

def lookup_76_78(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 77), u => lookup_76_77(index), u => lookup_77_78(index))

def lookup_78_79(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2043150526, 1610124483}, 0}, Fixed.Fixed{Core.Wide{1405236919, 2357139177}, 4294967293}, Core.Wide{8352133, 2533447353}}

def lookup_79_80(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2034266727, 122034290}, 0}, Fixed.Fixed{Core.Wide{1427486375, 564194035}, 4294967293}, Core.Wide{8352226, 2668192376}}

def lookup_78_80(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 79), u => lookup_78_79(index), u => lookup_79_80(index))

def lookup_76_80(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 78), u => lookup_76_78(index), u => lookup_78_80(index))

def lookup_72_80(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 76), u => lookup_72_76(index), u => lookup_76_80(index))

def lookup_64_80(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 72), u => lookup_64_72(index), u => lookup_72_80(index))

def lookup_80_81(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2025444115, 2837171370}, 0}, Fixed.Fixed{Core.Wide{1449832995, 3430273350}, 4294967293}, Core.Wide{8352314, 1342191221}}

def lookup_81_82(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2016680941, 659055673}, 0}, Fixed.Fixed{Core.Wide{1472276955, 3792699689}, 4294967293}, Core.Wide{8352396, 3396517295}}

def lookup_80_82(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 81), u => lookup_80_81(index), u => lookup_81_82(index))

def lookup_82_83(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2007975509, 1220071466}, 0}, Fixed.Fixed{Core.Wide{1494818442, 3083243294}, 4294967293}, Core.Wide{8352474, 756630597}}

def lookup_83_84(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1999326179, 4045680252}, 0}, Fixed.Fixed{Core.Wide{1517457656, 2278131126}, 4294967293}, Core.Wide{8352546, 2498757625}}

def lookup_82_84(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 83), u => lookup_82_83(index), u => lookup_83_84(index))

def lookup_80_84(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 82), u => lookup_80_82(index), u => lookup_82_84(index))

def lookup_84_85(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1990731364, 2176432577}, 0}, Fixed.Fixed{Core.Wide{1540194810, 1495033083}, 4294967293}, Core.Wide{8352614, 491645683}}

def lookup_85_86(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1982189523, 1609470295}, 0}, Fixed.Fixed{Core.Wide{1563030129, 3939934397}, 4294967293}, Core.Wide{8352676, 3757686777}}

def lookup_84_86(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 85), u => lookup_84_85(index), u => lookup_85_86(index))

def lookup_86_87(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1973699163, 2680457830}, 0}, Fixed.Fixed{Core.Wide{1585963853, 2727120257}, 4294967293}, Core.Wide{8352734, 4114465854}}

def lookup_87_88(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1965258836, 3474529463}, 0}, Fixed.Fixed{Core.Wide{1608996232, 2110115998}, 4294967293}, Core.Wide{8352788, 1945759718}}

def lookup_86_88(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 87), u => lookup_86_87(index), u => lookup_87_88(index))

def lookup_84_88(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 86), u => lookup_84_86(index), u => lookup_86_88(index))

def lookup_80_88(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 84), u => lookup_80_84(index), u => lookup_84_88(index))

def lookup_88_89(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1956867136, 3753673048}, 0}, Fixed.Fixed{Core.Wide{1632127530, 107536247}, 4294967293}, Core.Wide{8352837, 1907680204}}

def lookup_89_90(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1948522698, 775797015}, 0}, Fixed.Fixed{Core.Wide{1655358022, 1241868174}, 4294967293}, Core.Wide{8352882, 44804267}}

def lookup_88_90(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 89), u => lookup_88_89(index), u => lookup_89_90(index))

def lookup_90_91(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1940224193, 2743131611}, 0}, Fixed.Fixed{Core.Wide{1678687997, 3555303932}, 4294967293}, Core.Wide{8352922, 971002312}}

def lookup_91_92(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1931970332, 4015668946}, 0}, Fixed.Fixed{Core.Wide{1702117757, 2851118078}, 4294967293}, Core.Wide{8352958, 690460445}}

def lookup_90_92(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 91), u => lookup_90_91(index), u => lookup_91_92(index))

def lookup_88_92(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 90), u => lookup_88_90(index), u => lookup_90_92(index))

def lookup_92_93(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1923759860, 3666521391}, 0}, Fixed.Fixed{Core.Wide{1725647615, 1274636008}, 4294967293}, Core.Wide{8352989, 3778378100}}

def lookup_93_94(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1915591555, 2929220731}, 0}, Fixed.Fixed{Core.Wide{1749277896, 3052990297}, 4294967293}, Core.Wide{8353017, 1906901283}}

def lookup_92_94(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 93), u => lookup_92_93(index), u => lookup_93_94(index))

def lookup_94_95(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1907464227, 2988184936}, 0}, Fixed.Fixed{Core.Wide{1773008940, 1687810106}, 4294967293}, Core.Wide{8353040, 3910608590}}

def lookup_95_96(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1899376717, 3090445147}, 0}, Fixed.Fixed{Core.Wide{1796841097, 1549800669}, 4294967293}, Core.Wide{8353060, 1427436566}}

def lookup_94_96(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 95), u => lookup_94_95(index), u => lookup_95_96(index))

def lookup_92_96(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 94), u => lookup_92_94(index), u => lookup_94_96(index))

def lookup_88_96(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 92), u => lookup_88_92(index), u => lookup_92_96(index))

def lookup_80_96(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 88), u => lookup_80_88(index), u => lookup_88_96(index))

def lookup_64_96(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 80), u => lookup_64_80(index), u => lookup_80_96(index))

def lookup_96_97(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1891327895, 3253253327}, 0}, Fixed.Fixed{Core.Wide{1820774731, 860153969}, 4294967293}, Core.Wide{8353075, 3259033891}}

def lookup_97_98(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1883316659, 2958720908}, 0}, Fixed.Fixed{Core.Wide{1844810218, 482781761}, 4294967293}, Core.Wide{8353087, 1011593886}}

def lookup_96_98(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 97), u => lookup_96_97(index), u => lookup_97_98(index))

def lookup_98_99(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1875341934, 112855460}, 0}, Fixed.Fixed{Core.Wide{1868947946, 4167206830}, 4294967293}, Core.Wide{8353094, 3456121583}}

def lookup_99_100(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1867402668, 3137505256}, 0}, Fixed.Fixed{Core.Wide{1893188319, 1651841160}, 4294967293}, Core.Wide{8353098, 2169184378}}

def lookup_98_100(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 99), u => lookup_98_99(index), u => lookup_99_100(index))

def lookup_96_100(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 98), u => lookup_96_98(index), u => lookup_98_100(index))

def lookup_100_101(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1859497838, 345356128}, 0}, Fixed.Fixed{Core.Wide{1917531749, 3346876853}, 4294967293}, Core.Wide{8353098, 1598134748}}

def lookup_101_102(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1851626439, 2547839544}, 0}, Fixed.Fixed{Core.Wide{1941978665, 2042570475}, 4294967293}, Core.Wide{8353094, 1881657426}}

def lookup_100_102(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 101), u => lookup_100_101(index), u => lookup_101_102(index))

def lookup_102_103(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1843787492, 4263813136}, 0}, Fixed.Fixed{Core.Wide{1966529506, 3376754629}, 4294967293}, Core.Wide{8353086, 3145119692}}

def lookup_103_104(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1835980039, 955519046}, 0}, Fixed.Fixed{Core.Wide{1991184727, 507516993}, 4294967293}, Core.Wide{8353075, 1205955464}}

def lookup_102_104(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 103), u => lookup_102_103(index), u => lookup_103_104(index))

def lookup_100_104(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 102), u => lookup_100_102(index), u => lookup_102_104(index))

def lookup_96_104(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 100), u => lookup_96_100(index), u => lookup_100_104(index))

def lookup_104_105(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1828203139, 2150630312}, 0}, Fixed.Fixed{Core.Wide{2015944793, 365298188}, 4294967293}, Core.Wide{8353060, 458888539}}

def lookup_105_106(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1820455874, 1784770511}, 0}, Fixed.Fixed{Core.Wide{2040810184, 2700305397}, 4294967293}, Core.Wide{8353041, 991323506}}

def lookup_104_106(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 105), u => lookup_104_105(index), u => lookup_105_106(index))

def lookup_106_107(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1812737343, 243559823}, 0}, Fixed.Fixed{Core.Wide{2065781395, 644937964}, 4294967293}, Core.Wide{8353018, 2878578589}}

def lookup_107_108(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1805046662, 785178484}, 0}, Fixed.Fixed{Core.Wide{2090858931, 2791518450}, 4294967293}, Core.Wide{8352992, 1889157849}}

def lookup_106_108(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 107), u => lookup_106_107(index), u => lookup_107_108(index))

def lookup_104_108(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 106), u => lookup_104_106(index), u => lookup_106_108(index))

def lookup_108_109(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1797382965, 1809268141}, 0}, Fixed.Fixed{Core.Wide{2116043314, 3771252110}, 4294967293}, Core.Wide{8352962, 2369867608}}

def lookup_109_110(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1789745402, 2143562025}, 0}, Fixed.Fixed{Core.Wide{2141335079, 2119102927}, 4294967293}, Core.Wide{8352929, 66137811}}

def lookup_108_110(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 109), u => lookup_108_109(index), u => lookup_109_110(index))

def lookup_110_111(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1782133138, 2160393577}, 0}, Fixed.Fixed{Core.Wide{1083367387, 500295233}, 4294967294}, Core.Wide{8352891, 3597025932}}

def lookup_111_112(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1774545353, 715562037}, 0}, Fixed.Fixed{Core.Wide{1096121481, 195514781}, 4294967294}, Core.Wide{8352851, 95623703}}

def lookup_110_112(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 111), u => lookup_110_111(index), u => lookup_111_112(index))

def lookup_108_112(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 110), u => lookup_108_110(index), u => lookup_110_112(index))

def lookup_104_112(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 108), u => lookup_104_108(index), u => lookup_108_112(index))

def lookup_96_112(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 104), u => lookup_96_104(index), u => lookup_104_112(index))

def lookup_112_113(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1766981240, 787360511}, 0}, Fixed.Fixed{Core.Wide{1108930110, 1091355503}, 4294967294}, Core.Wide{8352806, 2453820823}}

def lookup_113_114(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1759440006, 2334226843}, 0}, Fixed.Fixed{Core.Wide{1121793570, 3372961794}, 4294967294}, Core.Wide{8352758, 2077767116}}

def lookup_112_114(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 113), u => lookup_112_113(index), u => lookup_113_114(index))

def lookup_114_115(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1751920871, 3839514236}, 0}, Fixed.Fixed{Core.Wide{1134712166, 472315245}, 4294967294}, Core.Wide{8352706, 3247692811}}

def lookup_115_116(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1744423067, 3947443669}, 0}, Fixed.Fixed{Core.Wide{1147686207, 1016100010}, 4294967294}, Core.Wide{8352651, 1643133906}}

def lookup_114_116(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 115), u => lookup_114_115(index), u => lookup_115_116(index))

def lookup_112_116(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 114), u => lookup_112_114(index), u => lookup_114_116(index))

def lookup_116_117(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1736945837, 3184545588}, 0}, Fixed.Fixed{Core.Wide{1160716012, 3552152507}, 4294967294}, Core.Wide{8352592, 1522843524}}

def lookup_117_118(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1729488435, 1466218176}, 0}, Fixed.Fixed{Core.Wide{1173801909, 1364432092}, 4294967294}, Core.Wide{8352529, 2839912813}}

def lookup_116_118(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 117), u => lookup_116_117(index), u => lookup_117_118(index))

def lookup_118_119(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1722050124, 4268163833}, 0}, Fixed.Fixed{Core.Wide{1186944231, 197210399}, 4294967294}, Core.Wide{8352463, 1241774601}}

def lookup_119_120(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1714630180, 3098069873}, 0}, Fixed.Fixed{Core.Wide{1200143320, 1644448694}, 4294967294}, Core.Wide{8352393, 955089969}}

def lookup_118_120(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 119), u => lookup_118_119(index), u => lookup_119_120(index))

def lookup_116_120(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 118), u => lookup_116_118(index), u => lookup_118_120(index))

def lookup_112_120(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 116), u => lookup_112_116(index), u => lookup_116_120(index))

def lookup_120_121(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1707227885, 3277307226}, 0}, Fixed.Fixed{Core.Wide{1213399527, 3744624469}, 4294967294}, Core.Wide{8352319, 1900812189}}

def lookup_121_122(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1699842532, 243936612}, 0}, Fixed.Fixed{Core.Wide{1226713212, 1601837298}, 4294967294}, Core.Wide{8352241, 3989101028}}

def lookup_120_122(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 121), u => lookup_120_121(index), u => lookup_121_122(index))

def lookup_122_123(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1692473419, 3156997857}, 0}, Fixed.Fixed{Core.Wide{1240084741, 918842247}, 4294967294}, Core.Wide{8352160, 2824283613}}

def lookup_123_124(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1685119856, 2718769890}, 0}, Fixed.Fixed{Core.Wide{1253514490, 1493133193}, 4294967294}, Core.Wide{8352075, 2589665569}}

def lookup_122_124(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 123), u => lookup_122_123(index), u => lookup_123_124(index))

def lookup_120_124(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 122), u => lookup_120_122(index), u => lookup_122_124(index))

def lookup_124_125(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1677781157, 3470148215}, 0}, Fixed.Fixed{Core.Wide{1267002844, 2216529824}, 4294967294}, Core.Wide{8351986, 3162519295}}

def lookup_125_126(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1670456645, 296263793}, 0}, Fixed.Fixed{Core.Wide{1280550197, 1809363781}, 4294967294}, Core.Wide{8351894, 113954865}}

def lookup_124_126(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 125), u => lookup_124_125(index), u => lookup_125_126(index))

def lookup_126_127(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1663145646, 2217899028}, 0}, Fixed.Fixed{Core.Wide{1294156951, 3880153030}, 4294967294}, Core.Wide{8351797, 1888640551}}

def lookup_127_128(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1655847496, 385945990}, 0}, Fixed.Fixed{Core.Wide{1307823520, 541972982}, 4294967294}, Core.Wide{8351696, 4034830493}}

def lookup_126_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 127), u => lookup_126_127(index), u => lookup_127_128(index))

def lookup_124_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 126), u => lookup_124_126(index), u => lookup_126_128(index))

def lookup_120_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 124), u => lookup_120_124(index), u => lookup_124_128(index))

def lookup_112_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 120), u => lookup_112_120(index), u => lookup_120_128(index))

def lookup_96_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 112), u => lookup_96_112(index), u => lookup_112_128(index))

def lookup_64_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 96), u => lookup_64_96(index), u => lookup_96_128(index))

def lookup_0_128(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 64), u => lookup_0_64(index), u => lookup_64_128(index))

def lookup_128_129(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1648561533, 534558930}, 0}, Fixed.Fixed{Core.Wide{1321550323, 3306073837}, 4294967294}, Core.Wide{8351592, 2089077757}}

def lookup_129_130(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1641287101, 3925547751}, 0}, Fixed.Fixed{Core.Wide{1335337794, 994795936}, 4294967294}, Core.Wide{8351484, 165959314}}

def lookup_128_130(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 129), u => lookup_128_129(index), u => lookup_129_130(index))

def lookup_130_131(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1634023551, 1205270343}, 0}, Fixed.Fixed{Core.Wide{1349186372, 3588775613}, 4294967294}, Core.Wide{8351371, 2367910547}}

def lookup_131_132(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1626770234, 645682722}, 0}, Fixed.Fixed{Core.Wide{1363096511, 211022060}, 4294967294}, Core.Wide{8351254, 4195037841}}

def lookup_130_132(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 131), u => lookup_130_131(index), u => lookup_131_132(index))

def lookup_128_132(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 130), u => lookup_128_130(index), u => lookup_130_132(index))

def lookup_132_133(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1619526507, 572119807}, 0}, Fixed.Fixed{Core.Wide{1377068670, 3047902795}, 4294967294}, Core.Wide{8351134, 1134777755}}

def lookup_133_134(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1612291730, 464026915}, 0}, Fixed.Fixed{Core.Wide{1391103324, 1114801674}, 4294967294}, Core.Wide{8351009, 1546500128}}

def lookup_132_134(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 133), u => lookup_132_133(index), u => lookup_133_134(index))

def lookup_134_135(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1605065265, 3480984808}, 0}, Fixed.Fixed{Core.Wide{1405200954, 4256580405}, 4294967294}, Core.Wide{8350880, 891381319}}

def lookup_135_136(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1597846479, 1821110665}, 0}, Fixed.Fixed{Core.Wide{1419362057, 1290774897}, 4294967294}, Core.Wide{8350746, 3206892558}}

def lookup_134_136(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 135), u => lookup_134_135(index), u => lookup_135_136(index))

def lookup_132_136(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 134), u => lookup_132_134(index), u => lookup_134_136(index))

def lookup_128_136(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 132), u => lookup_128_132(index), u => lookup_132_136(index))

def lookup_136_137(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1590634738, 743451030}, 0}, Fixed.Fixed{Core.Wide{1433587136, 4093899520}, 4294967294}, Core.Wide{8350608, 3926556480}}

def lookup_137_138(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1583429410, 3942011321}, 0}, Fixed.Fixed{Core.Wide{1447876711, 1538977310}, 4294967294}, Core.Wide{8350466, 2764447463}}

def lookup_136_138(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 137), u => lookup_136_137(index), u => lookup_137_138(index))

def lookup_138_139(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1576229867, 3218156012}, 0}, Fixed.Fixed{Core.Wide{1462231309, 3674801177}, 4294967294}, Core.Wide{8350319, 3714761582}}

def lookup_139_140(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1569035479, 2513207399}, 0}, Fixed.Fixed{Core.Wide{1476651474, 55253086}, 4294967294}, Core.Wide{8350168, 2166454883}}

def lookup_138_140(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 139), u => lookup_138_139(index), u => lookup_139_140(index))

def lookup_136_140(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 138), u => lookup_136_138(index), u => lookup_138_140(index))

def lookup_140_141(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1561845617, 3283841857}, 0}, Fixed.Fixed{Core.Wide{1491137757, 4019472967}, 4294967294}, Core.Wide{8350012, 2082621465}}

def lookup_141_142(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1554659653, 2756910463}, 0}, Fixed.Fixed{Core.Wide{1505690728, 2536471646}, 4294967294}, Core.Wide{8349851, 3115067713}}

def lookup_140_142(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 141), u => lookup_140_141(index), u => lookup_141_142(index))

def lookup_142_143(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1547476958, 765702472}, 0}, Fixed.Fixed{Core.Wide{1520310966, 595097622}, 4294967294}, Core.Wide{8349686, 603753915}}

def lookup_143_144(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1540296901, 2279691872}, 0}, Fixed.Fixed{Core.Wide{1534999064, 1228052706}, 4294967294}, Core.Wide{8349515, 2756068764}}

def lookup_142_144(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 143), u => lookup_142_143(index), u => lookup_143_144(index))

def lookup_140_144(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 142), u => lookup_140_142(index), u => lookup_142_144(index))

def lookup_136_144(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 140), u => lookup_136_140(index), u => lookup_140_144(index))

def lookup_128_144(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 136), u => lookup_128_136(index), u => lookup_136_144(index))

def lookup_144_145(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1533118852, 2739753155}, 0}, Fixed.Fixed{Core.Wide{1549755630, 2776964766}, 4294967294}, Core.Wide{8349340, 581425322}}

def lookup_145_146(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1525942178, 3440309699}, 0}, Fixed.Fixed{Core.Wide{1564581287, 516399205}, 4294967294}, Core.Wide{8349159, 2250326002}}

def lookup_144_146(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 145), u => lookup_144_145(index), u => lookup_145_146(index))

def lookup_146_147(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1518766245, 1120586975}, 0}, Fixed.Fixed{Core.Wide{1579476670, 1229691109}, 4294967294}, Core.Wide{8348973, 3028875399}}

def lookup_147_148(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1511590414, 3301237480}, 0}, Fixed.Fixed{Core.Wide{1594442431, 3495079650}, 4294967294}, Core.Wide{8348782, 2457888160}}

def lookup_146_148(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 147), u => lookup_146_147(index), u => lookup_147_148(index))

def lookup_144_148(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 146), u => lookup_144_146(index), u => lookup_146_148(index))

def lookup_148_149(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1504414047, 643420011}, 0}, Fixed.Fixed{Core.Wide{1609479238, 3814994768}, 4294967294}, Core.Wide{8348586, 57112481}}

def lookup_149_150(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1497236498, 3700962260}, 0}, Fixed.Fixed{Core.Wide{1624587774, 2822198668}, 4294967294}, Core.Wide{8348383, 3914304691}}

def lookup_148_150(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 149), u => lookup_148_149(index), u => lookup_149_150(index))

def lookup_150_151(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1490057122, 2328006168}, 0}, Fixed.Fixed{Core.Wide{1639768738, 2976565721}, 4294967294}, Core.Wide{8348176, 619544218}}

def lookup_151_152(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1482875266, 2357138216}, 0}, Fixed.Fixed{Core.Wide{1655022847, 2051412528}, 4294967294}, Core.Wide{8347962, 2508902564}}

def lookup_150_152(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 151), u => lookup_150_151(index), u => lookup_151_152(index))

def lookup_148_152(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 150), u => lookup_148_150(index), u => lookup_150_152(index))

def lookup_144_152(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 148), u => lookup_144_148(index), u => lookup_148_152(index))

def lookup_152_153(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1475690274, 2105074754}, 0}, Fixed.Fixed{Core.Wide{1670350834, 3888401056}, 4294967294}, Core.Wide{8347743, 418770755}}

def lookup_153_154(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1468501484, 3191034341}, 0}, Fixed.Fixed{Core.Wide{1685753452, 3475787117}, 4294967294}, Core.Wide{8347517, 2339467759}}

def lookup_152_154(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 153), u => lookup_152_153(index), u => lookup_153_154(index))

def lookup_154_155(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1461308229, 4123851475}, 0}, Fixed.Fixed{Core.Wide{1701231471, 2189311342}, 4294967294}, Core.Wide{8347285, 3349302910}}

def lookup_155_156(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1454109836, 2423089442}, 0}, Fixed.Fixed{Core.Wide{1716785680, 1661144267}, 4294967294}, Core.Wide{8347047, 2793204704}}

def lookup_154_156(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 155), u => lookup_154_155(index), u => lookup_155_156(index))

def lookup_152_156(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 154), u => lookup_152_154(index), u => lookup_154_156(index))

def lookup_156_157(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1446905624, 974410962}, 0}, Fixed.Fixed{Core.Wide{1732416888, 2052026704}, 4294967294}, Core.Wide{8346802, 4281401499}}

def lookup_157_158(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1439694905, 1434314068}, 0}, Fixed.Fixed{Core.Wide{1748125925, 437316964}, 4294967294}, Core.Wide{8346551, 2803115981}}

def lookup_156_158(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 157), u => lookup_156_157(index), u => lookup_157_158(index))

def lookup_158_159(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1432476984, 1858806558}, 0}, Fixed.Fixed{Core.Wide{1763913640, 2197892244}, 4294967294}, Core.Wide{8346293, 1904940450}}

def lookup_159_160(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1425251157, 2845393067}, 0}, Fixed.Fixed{Core.Wide{1779780906, 2472670597}, 4294967294}, Core.Wide{8346028, 804344404}}

def lookup_158_160(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 159), u => lookup_158_159(index), u => lookup_159_160(index))

def lookup_156_160(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 158), u => lookup_156_158(index), u => lookup_158_160(index))

def lookup_152_160(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 156), u => lookup_152_156(index), u => lookup_156_160(index))

def lookup_144_160(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 152), u => lookup_144_152(index), u => lookup_152_160(index))

def lookup_128_160(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 144), u => lookup_128_144(index), u => lookup_144_160(index))

def lookup_160_161(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1418016712, 707620585}, 0}, Fixed.Fixed{Core.Wide{1795728617, 2104125832}, 4294967294}, Core.Wide{8345755, 2977915027}}

def lookup_161_162(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1410772925, 2035649463}, 0}, Fixed.Fixed{Core.Wide{1811757690, 2249539226}, 4294967294}, Core.Wide{8345475, 3274650081}}

def lookup_160_162(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 161), u => lookup_160_161(index), u => lookup_161_162(index))

def lookup_162_163(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1403519064, 3801618208}, 0}, Fixed.Fixed{Core.Wide{1827869066, 3435601445}, 4294967294}, Core.Wide{8345188, 798935293}}

def lookup_163_164(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1396254386, 3427234644}, 0}, Fixed.Fixed{Core.Wide{1844063712, 474768795}, 4294967294}, Core.Wide{8344892, 3203458939}}

def lookup_162_164(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 163), u => lookup_162_163(index), u => lookup_163_164(index))

def lookup_160_164(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 162), u => lookup_160_162(index), u => lookup_162_164(index))

def lookup_164_165(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1388978136, 151353176}, 0}, Fixed.Fixed{Core.Wide{1860342617, 3317054285}, 4294967294}, Core.Wide{8344589, 917217485}}

def lookup_165_166(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1381689545, 574406643}, 0}, Fixed.Fixed{Core.Wide{1876706801, 2242400448}, 4294967294}, Core.Wide{8344277, 1502914917}}

def lookup_164_166(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 165), u => lookup_164_165(index), u => lookup_165_166(index))

def lookup_166_167(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1374387833, 2601311885}, 0}, Fixed.Fixed{Core.Wide{1893157308, 1957876742}, 4294967294}, Core.Wide{8343956, 3884660001}}

def lookup_167_168(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1367072207, 723352055}, 0}, Fixed.Fixed{Core.Wide{1909695212, 56561115}, 4294967294}, Core.Wide{8343627, 2640262108}}

def lookup_166_168(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 167), u => lookup_166_167(index), u => lookup_167_168(index))

def lookup_164_168(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 166), u => lookup_164_166(index), u => lookup_166_168(index))

def lookup_160_168(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 164), u => lookup_160_164(index), u => lookup_164_168(index))

def lookup_168_169(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1359741856, 4039284521}, 0}, Fixed.Fixed{Core.Wide{1926321615, 44109197}, 4294967294}, Core.Wide{8343289, 883275433}}

def lookup_169_170(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1352395958, 2580642677}, 0}, Fixed.Fixed{Core.Wide{1943037650, 3110970605}, 4294967294}, Core.Wide{8342941, 1670005549}}

def lookup_168_170(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 169), u => lookup_168_169(index), u => lookup_169_170(index))

def lookup_170_171(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1345033671, 2189023219}, 0}, Fixed.Fixed{Core.Wide{1959844484, 138538244}, 4294967294}, Core.Wide{8342583, 3701265677}}

def lookup_171_172(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1337654137, 3379172688}, 0}, Fixed.Fixed{Core.Wide{1976743312, 2608378861}, 4294967294}, Core.Wide{8342216, 1318864724}}

def lookup_170_172(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 171), u => lookup_170_171(index), u => lookup_171_172(index))

def lookup_168_172(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 170), u => lookup_168_170(index), u => lookup_170_172(index))

def lookup_172_173(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1330256481, 1484229622}, 0}, Fixed.Fixed{Core.Wide{1993735368, 760916490}, 4294967294}, Core.Wide{8341838, 1681709285}}

def lookup_173_174(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1322839806, 3774093005}, 0}, Fixed.Fixed{Core.Wide{2010821917, 3639085818}, 4294967294}, Core.Wide{8341449, 3286923185}}

def lookup_172_174(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 173), u => lookup_172_173(index), u => lookup_173_174(index))

def lookup_174_175(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1315403198, 3402210150}, 0}, Fixed.Fixed{Core.Wide{2028004265, 2121136470}, 4294967294}, Core.Wide{8341050, 260470240}}

def lookup_175_176(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1307945720, 358724081}, 0}, Fixed.Fixed{Core.Wide{2045283753, 990838087}, 4294967294}, Core.Wide{8340638, 3827319587}}

def lookup_174_176(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 175), u => lookup_174_175(index), u => lookup_175_176(index))

def lookup_172_176(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 174), u => lookup_172_174(index), u => lookup_174_176(index))

def lookup_168_176(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 172), u => lookup_168_172(index), u => lookup_172_176(index))

def lookup_160_176(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 168), u => lookup_160_168(index), u => lookup_168_176(index))

def lookup_176_177(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1300466411, 692804979}, 0}, Fixed.Fixed{Core.Wide{2062661762, 4101847762}, 4294967294}, Core.Wide{8340215, 3651713496}}

def lookup_177_178(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1292964288, 2574946234}, 0}, Fixed.Fixed{Core.Wide{2080139717, 4198381860}, 4294967294}, Core.Wide{8339780, 2191492194}}

def lookup_176_178(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 177), u => lookup_176_177(index), u => lookup_177_178(index))

def lookup_178_179(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1285438343, 3538209982}, 0}, Fixed.Fixed{Core.Wide{2097719084, 3186340117}, 4294967294}, Core.Wide{8339332, 1807356439}}

def lookup_179_180(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1277887541, 3106105233}, 0}, Fixed.Fixed{Core.Wide{2115401374, 2751663933}, 4294967294}, Core.Wide{8338871, 461604110}}

def lookup_178_180(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 179), u => lookup_178_179(index), u => lookup_179_180(index))

def lookup_176_180(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 178), u => lookup_176_178(index), u => lookup_178_180(index))

def lookup_180_181(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1270310819, 782647563}, 0}, Fixed.Fixed{Core.Wide{2133188145, 4009127184}, 4294967294}, Core.Wide{8338396, 301265355}}

def lookup_181_182(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1262707083, 2262914554}, 0}, Fixed.Fixed{Core.Wide{1075540502, 3811247820}, 4294967295}, Core.Wide{8337906, 3355785225}}

def lookup_180_182(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 181), u => lookup_180_181(index), u => lookup_181_182(index))

def lookup_182_183(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1255075210, 3770379694}, 0}, Fixed.Fixed{Core.Wide{1084540806, 772317281}, 4294967295}, Core.Wide{8337402, 2939135888}}

def lookup_183_184(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1247414044, 1734112196}, 0}, Fixed.Fixed{Core.Wide{1093595838, 2566696152}, 4294967295}, Core.Wide{8336883, 821071191}}

def lookup_182_184(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 183), u => lookup_182_183(index), u => lookup_183_184(index))

def lookup_180_184(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 182), u => lookup_180_182(index), u => lookup_182_184(index))

def lookup_176_184(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 180), u => lookup_176_180(index), u => lookup_180_184(index))

def lookup_184_185(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1239722392, 2001601943}, 0}, Fixed.Fixed{Core.Wide{1102706483, 3237006032}, 4294967295}, Core.Wide{8336347, 2922818497}}

def lookup_185_186(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1231999026, 2779773080}, 0}, Fixed.Fixed{Core.Wide{1111873654, 1702229461}, 4294967295}, Core.Wide{8335795, 2127070143}}

def lookup_184_186(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 185), u => lookup_184_185(index), u => lookup_185_186(index))

def lookup_186_187(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1224242679, 2802615809}, 0}, Fixed.Fixed{Core.Wide{1121098293, 3278285538}, 4294967295}, Core.Wide{8335225, 4036768841}}

def lookup_187_188(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1216452043, 320581230}, 0}, Fixed.Fixed{Core.Wide{1130381377, 84570285}, 4294967295}, Core.Wide{8334638, 1193316499}}

def lookup_186_188(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 187), u => lookup_186_187(index), u => lookup_187_188(index))

def lookup_184_188(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 186), u => lookup_184_186(index), u => lookup_186_188(index))

def lookup_188_189(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1208625765, 42109717}, 0}, Fixed.Fixed{Core.Wide{1139723912, 3378789188}, 4294967295}, Core.Wide{8334031, 3128288185}}

def lookup_189_190(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1200762447, 2203108088}, 0}, Fixed.Fixed{Core.Wide{1149126944, 3296514338}, 4294967295}, Core.Wide{8333405, 1989454116}}

def lookup_188_190(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 189), u => lookup_188_189(index), u => lookup_189_190(index))

def lookup_190_191(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1192860643, 3769317947}, 0}, Fixed.Fixed{Core.Wide{1158591553, 2057723776}, 4294967295}, Core.Wide{8332758, 2590001887}}

def lookup_191_192(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1184918855, 3115723559}, 0}, Fixed.Fixed{Core.Wide{1168118858, 417814898}, 4294967295}, Core.Wide{8332090, 916699556}}

def lookup_190_192(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 191), u => lookup_190_191(index), u => lookup_191_192(index))

def lookup_188_192(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 190), u => lookup_188_190(index), u => lookup_190_192(index))

def lookup_184_192(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 188), u => lookup_184_188(index), u => lookup_188_192(index))

def lookup_176_192(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 184), u => lookup_176_184(index), u => lookup_184_192(index))

def lookup_160_192(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 176), u => lookup_160_176(index), u => lookup_176_192(index))

def lookup_128_192(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 160), u => lookup_128_160(index), u => lookup_160_192(index))

def lookup_192_193(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1176935529, 3815299764}, 0}, Fixed.Fixed{Core.Wide{1177710018, 1827746369}, 4294967295}, Core.Wide{8331399, 1291152372}}

def lookup_193_194(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1168909055, 276857226}, 0}, Fixed.Fixed{Core.Wide{1187366236, 4282660772}, 4294967295}, Core.Wide{8330684, 3464495445}}

def lookup_192_194(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 193), u => lookup_192_193(index), u => lookup_193_194(index))

def lookup_194_195(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1160837758, 977603860}, 0}, Fixed.Fixed{Core.Wide{1197088761, 1382389860}, 4294967295}, Core.Wide{8329945, 2594990679}}

def lookup_195_196(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1152719900, 3292464142}, 0}, Fixed.Fixed{Core.Wide{1206878886, 1247310604}, 4294967295}, Core.Wide{8329180, 2108296241}}

def lookup_194_196(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 195), u => lookup_194_195(index), u => lookup_195_196(index))

def lookup_192_196(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 194), u => lookup_192_194(index), u => lookup_194_196(index))

def lookup_196_197(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1144553674, 1415037883}, 0}, Fixed.Fixed{Core.Wide{1216737956, 3219109862}, 4294967295}, Core.Wide{8328388, 785439887}}

def lookup_197_198(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1136337196, 1478605457}, 0}, Fixed.Fixed{Core.Wide{1226667370, 1131282080}, 4294967295}, Core.Wide{8327567, 1322837323}}

def lookup_196_198(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 197), u => lookup_196_197(index), u => lookup_197_198(index))

def lookup_198_199(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1128068505, 791808515}, 0}, Fixed.Fixed{Core.Wide{1236668580, 336831306}, 4294967295}, Core.Wide{8326716, 1709309126}}

def lookup_199_200(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1119745554, 4051982488}, 0}, Fixed.Fixed{Core.Wide{1246743098, 1328825527}, 4294967295}, Core.Wide{8325833, 3779445342}}

def lookup_198_200(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 199), u => lookup_198_199(index), u => lookup_199_200(index))

def lookup_196_200(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 198), u => lookup_196_198(index), u => lookup_198_200(index))

def lookup_192_200(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 196), u => lookup_192_196(index), u => lookup_196_200(index))

def lookup_200_201(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1111366209, 3352312436}, 0}, Fixed.Fixed{Core.Wide{1256892499, 1582634260}, 4294967295}, Core.Wide{8324918, 288166594}}

def lookup_201_202(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1102928237, 3397406493}, 0}, Fixed.Fixed{Core.Wide{1267118423, 2834277888}, 4294967295}, Core.Wide{8323967, 635512717}}

def lookup_200_202(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 201), u => lookup_200_201(index), u => lookup_201_202(index))

def lookup_202_203(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1094429304, 1519910372}, 0}, Fixed.Fixed{Core.Wide{1277422581, 2430839588}, 4294967295}, Core.Wide{8322979, 751790582}}

def lookup_203_204(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1085866964, 3862852508}, 0}, Fixed.Fixed{Core.Wide{1287806757, 3236480861}, 4294967295}, Core.Wide{8321952, 221618545}}

def lookup_202_204(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 203), u => lookup_202_203(index), u => lookup_203_204(index))

def lookup_200_204(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 202), u => lookup_200_202(index), u => lookup_202_204(index))

def lookup_204_205(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1077238657, 148093272}, 0}, Fixed.Fixed{Core.Wide{1298272815, 3577977038}, 4294967295}, Core.Wide{8320883, 2221574771}}

def lookup_205_206(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2137083383, 3904553591}, 4294967295}, Fixed.Fixed{Core.Wide{1308822703, 1745046007}, 4294967295}, Core.Wide{8319771, 565508892}}

def lookup_204_206(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 205), u => lookup_204_205(index), u => lookup_205_206(index))

def lookup_206_207(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2119546490, 526305702}, 4294967295}, Fixed.Fixed{Core.Wide{1319458457, 2335452290}, 4294967295}, Core.Wide{8318612, 1101102205}}

def lookup_207_208(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2101860691, 1675243256}, 4294967295}, Fixed.Fixed{Core.Wide{1330182210, 3167126057}, 4294967295}, Core.Wide{8317404, 147035371}}

def lookup_206_208(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 207), u => lookup_206_207(index), u => lookup_207_208(index))

def lookup_204_208(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 206), u => lookup_204_206(index), u => lookup_206_208(index))

def lookup_200_208(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 204), u => lookup_200_204(index), u => lookup_204_208(index))

def lookup_192_208(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 200), u => lookup_192_200(index), u => lookup_200_208(index))

def lookup_208_209(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2084019731, 3246958706}, 4294967295}, Fixed.Fixed{Core.Wide{1340996197, 1634598191}, 4294967295}, Core.Wide{8316143, 1573704680}}

def lookup_209_210(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2066017015, 3859499147}, 4294967295}, Fixed.Fixed{Core.Wide{1351902760, 3581903075}, 4294967295}, Core.Wide{8314826, 3806324358}}

def lookup_208_210(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 209), u => lookup_208_209(index), u => lookup_209_210(index))

def lookup_210_211(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2047845581, 3921416325}, 4294967295}, Fixed.Fixed{Core.Wide{1362904361, 618256724}, 4294967295}, Core.Wide{8313450, 3993071870}}

def lookup_211_212(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2029498071, 1270352148}, 4294967295}, Fixed.Fixed{Core.Wide{1374003583, 2101361946}, 4294967295}, Core.Wide{8312011, 2156065885}}

def lookup_210_212(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 211), u => lookup_210_211(index), u => lookup_211_212(index))

def lookup_208_212(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 210), u => lookup_208_210(index), u => lookup_210_212(index))

def lookup_212_213(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2010966695, 3319355809}, 4294967295}, Fixed.Fixed{Core.Wide{1385203147, 1900664567}, 4294967295}, Core.Wide{8310504, 1027436181}}

def lookup_213_214(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1992243200, 2397249209}, 4294967295}, Fixed.Fixed{Core.Wide{1396505917, 624621135}, 4294967295}, Core.Wide{8308924, 1567188061}}

def lookup_212_214(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 213), u => lookup_212_213(index), u => lookup_213_214(index))

def lookup_214_215(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1973318823, 2424065804}, 4294967295}, Fixed.Fixed{Core.Wide{1407914912, 2195296953}, 4294967295}, Core.Wide{8307266, 2748860225}}

def lookup_215_216(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1954184250, 48049468}, 4294967295}, Fixed.Fixed{Core.Wide{1419433321, 2511555399}, 4294967295}, Core.Wide{8305525, 1313292689}}

def lookup_214_216(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 215), u => lookup_214_215(index), u => lookup_215_216(index))

def lookup_212_216(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 214), u => lookup_212_214(index), u => lookup_214_216(index))

def lookup_208_216(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 212), u => lookup_208_212(index), u => lookup_212_216(index))

def lookup_216_217(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1934829561, 3365551397}, 4294967295}, Fixed.Fixed{Core.Wide{1431064514, 913903135}, 4294967295}, Core.Wide{8303694, 74764129}}

def lookup_217_218(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1915244180, 3371014130}, 4294967295}, Fixed.Fixed{Core.Wide{1442812057, 842412107}, 4294967295}, Core.Wide{8301765, 3297802903}}

def lookup_216_218(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 217), u => lookup_216_217(index), u => lookup_217_218(index))

def lookup_218_219(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1895416805, 1698422707}, 4294967295}, Fixed.Fixed{Core.Wide{1454679731, 561124814}, 4294967295}, Core.Wide{8299732, 3431310284}}

def lookup_219_220(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1875335338, 4261995177}, 4294967295}, Fixed.Fixed{Core.Wide{1466671549, 738039966}, 4294967295}, Core.Wide{8297586, 2139506928}}

def lookup_218_220(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 219), u => lookup_218_219(index), u => lookup_219_220(index))

def lookup_216_220(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 218), u => lookup_216_218(index), u => lookup_218_220(index))

def lookup_220_221(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1854986809, 1249706110}, 4294967295}, Fixed.Fixed{Core.Wide{1478791778, 10061265}, 4294967295}, Core.Wide{8295317, 1192731265}}

def lookup_221_222(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1834357277, 166247236}, 4294967295}, Fixed.Fixed{Core.Wide{1491044961, 1412452988}, 4294967295}, Core.Wide{8292914, 1857431339}}

def lookup_220_222(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 221), u => lookup_220_221(index), u => lookup_221_222(index))

def lookup_222_223(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1813431732, 1303545622}, 4294967295}, Fixed.Fixed{Core.Wide{1503435946, 1267498558}, 4294967295}, Core.Wide{8290365, 4176365959}}

def lookup_223_224(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1792193976, 1079564548}, 4294967295}, Fixed.Fixed{Core.Wide{1515969913, 1156356312}, 4294967295}, Core.Wide{8287658, 1820288200}}

def lookup_222_224(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 223), u => lookup_222_223(index), u => lookup_223_224(index))

def lookup_220_224(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 222), u => lookup_220_222(index), u => lookup_222_224(index))

def lookup_216_224(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 220), u => lookup_216_220(index), u => lookup_220_224(index))

def lookup_208_224(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 216), u => lookup_208_216(index), u => lookup_216_224(index))

def lookup_192_224(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 208), u => lookup_192_208(index), u => lookup_208_224(index))

def lookup_224_225(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1770626485, 3744824216}, 4294967295}, Fixed.Fixed{Core.Wide{1528652409, 2372539995}, 4294967295}, Core.Wide{8284776, 2546060834}}

def lookup_225_226(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1748710258, 2459747768}, 4294967295}, Fixed.Fixed{Core.Wide{1541489387, 2850794159}, 4294967295}, Core.Wide{8281703, 1209080016}}

def lookup_224_226(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 225), u => lookup_224_225(index), u => lookup_225_226(index))

def lookup_226_227(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1726424632, 3809817135}, 4294967295}, Fixed.Fixed{Core.Wide{1554487248, 4256446755}, 4294967295}, Core.Wide{8278418, 4066309161}}

def lookup_227_228(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1703747080, 2960900489}, 4294967295}, Fixed.Fixed{Core.Wide{1567652893, 3277932859}, 4294967295}, Core.Wide{8274901, 1229239589}}

def lookup_226_228(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 227), u => lookup_226_227(index), u => lookup_227_228(index))

def lookup_224_228(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 226), u => lookup_224_226(index), u => lookup_226_228(index))

def lookup_228_229(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1680652965, 993949952}, 4294967295}, Fixed.Fixed{Core.Wide{1580993778, 2193835539}, 4294967295}, Core.Wide{8271124, 3151458689}}

def lookup_229_230(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1657115257, 3990518719}, 4294967295}, Fixed.Fixed{Core.Wide{1594517982, 1906398066}, 4294967295}, Core.Wide{8267059, 3608338057}}

def lookup_228_230(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 229), u => lookup_228_229(index), u => lookup_229_230(index))

def lookup_230_231(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1633104205, 204075576}, 4294967295}, Fixed.Fixed{Core.Wide{1608234284, 2206933061}, 4294967295}, Core.Wide{8262672, 2176651842}}

def lookup_231_232(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1608586933, 466953246}, 4294967295}, Fixed.Fixed{Core.Wide{1622152253, 1530768084}, 4294967295}, Core.Wide{8257923, 133915322}}

def lookup_230_232(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 231), u => lookup_230_231(index), u => lookup_231_232(index))

def lookup_228_232(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 230), u => lookup_228_230(index), u => lookup_230_232(index))

def lookup_224_232(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 228), u => lookup_224_228(index), u => lookup_228_232(index))

def lookup_232_233(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1583526978, 3433690669}, 4294967295}, Fixed.Fixed{Core.Wide{1636282352, 3740442337}, 4294967295}, Core.Wide{8252764, 3894435695}}

def lookup_233_234(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1557883725, 467842475}, 4294967295}, Fixed.Fixed{Core.Wide{1650636066, 3950770321}, 4294967295}, Core.Wide{8247143, 1292839013}}

def lookup_232_234(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 233), u => lookup_232_233(index), u => lookup_233_234(index))

def lookup_234_235(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1531611720, 1432061}, 4294967295}, Fixed.Fixed{Core.Wide{1665226047, 2552926322}, 4294967295}, Core.Wide{8240993, 456651708}}

def lookup_235_236(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1504659846, 2381385805}, 4294967295}, Fixed.Fixed{Core.Wide{1680066292, 3318033355}, 4294967295}, Core.Wide{8234236, 1788585517}}

def lookup_234_236(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 235), u => lookup_234_235(index), u => lookup_235_236(index))

def lookup_232_236(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 234), u => lookup_232_234(index), u => lookup_234_236(index))

def lookup_236_237(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1476970303, 1710998494}, 4294967295}, Fixed.Fixed{Core.Wide{1695172360, 1843989855}, 4294967295}, Core.Wide{8226779, 952486002}}

def lookup_237_238(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1448477340, 523923514}, 4294967295}, Fixed.Fixed{Core.Wide{1710561629, 2246768301}, 4294967295}, Core.Wide{8218507, 110798559}}

def lookup_236_238(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 237), u => lookup_236_237(index), u => lookup_237_238(index))

def lookup_238_239(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1419105672, 1800267082}, 4294967295}, Fixed.Fixed{Core.Wide{1726253620, 2417621071}, 4294967295}, Core.Wide{8209278, 4074397637}}

def lookup_239_240(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1388768472, 4160402793}, 4294967295}, Fixed.Fixed{Core.Wide{1742270393, 2491372219}, 4294967295}, Core.Wide{8198919, 2886718357}}

def lookup_238_240(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 239), u => lookup_238_239(index), u => lookup_239_240(index))

def lookup_236_240(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 238), u => lookup_236_238(index), u => lookup_238_240(index))

def lookup_232_240(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 236), u => lookup_232_236(index), u => lookup_236_240(index))

def lookup_224_240(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 232), u => lookup_224_232(index), u => lookup_232_240(index))

def lookup_240_241(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1357364791, 4268583224}, 4294967295}, Fixed.Fixed{Core.Wide{1758637047, 3602657311}, 4294967295}, Core.Wide{8187208, 1054844997}}

def lookup_241_242(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1324776198, 2328154162}, 4294967295}, Fixed.Fixed{Core.Wide{1775382357, 1126660448}, 4294967295}, Core.Wide{8173862, 980322000}}

def lookup_240_242(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 241), u => lookup_240_241(index), u => lookup_241_242(index))

def lookup_242_243(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1290862337, 1581770350}, 4294967295}, Fixed.Fixed{Core.Wide{1792539589, 3902014998}, 4294967295}, Core.Wide{8158514, 3155767020}}

def lookup_243_244(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1255454945, 2405569183}, 4294967295}, Fixed.Fixed{Core.Wide{1810147581, 3013770814}, 4294967295}, Core.Wide{8140680, 1662697110}}

def lookup_242_244(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 243), u => lookup_242_243(index), u => lookup_243_244(index))

def lookup_240_244(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 242), u => lookup_240_242(index), u => lookup_242_244(index))

def lookup_244_245(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1218349629, 3899385422}, 4294967295}, Fixed.Fixed{Core.Wide{1828252168, 3547608732}, 4294967295}, Core.Wide{8119703, 1631724762}}

def lookup_245_246(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1179294301, 81392391}, 4294967295}, Fixed.Fixed{Core.Wide{1846908138, 1070939501}, 4294967295}, Core.Wide{8094675, 2862396709}}

def lookup_244_246(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 245), u => lookup_244_245(index), u => lookup_245_246(index))

def lookup_246_247(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1137972460, 158672404}, 4294967295}, Fixed.Fixed{Core.Wide{1866181947, 2272394234}, 4294967295}, Core.Wide{8064303, 551361715}}

def lookup_247_248(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1093978270, 988729466}, 4294967295}, Fixed.Fixed{Core.Wide{1886155623, 3136003048}, 4294967295}, Core.Wide{8026676, 2869504731}}

def lookup_246_248(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 247), u => lookup_246_247(index), u => lookup_247_248(index))

def lookup_244_248(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 246), u => lookup_244_246(index), u => lookup_246_248(index))

def lookup_240_248(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 244), u => lookup_240_244(index), u => lookup_244_248(index))

def lookup_248_249(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{2093555893, 861356426}, 4294967294}, Fixed.Fixed{Core.Wide{1906932538, 2783047813}, 4294967295}, Core.Wide{7978859, 268327098}}

def lookup_249_250(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1991294313, 3519677231}, 4294967294}, Fixed.Fixed{Core.Wide{1928646306, 2629280207}, 4294967295}, Core.Wide{7916088, 1473389916}}

def lookup_248_250(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 249), u => lookup_248_249(index), u => lookup_249_250(index))

def lookup_250_251(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1879127228, 3783793463}, 4294967294}, Fixed.Fixed{Core.Wide{1951475170, 2221368235}, 4294967295}, Core.Wide{7830108, 200693191}}

def lookup_251_252(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1754017977, 860039792}, 4294967294}, Fixed.Fixed{Core.Wide{1975666713, 1593031894}, 4294967295}, Core.Wide{7705263, 1319091186}}

def lookup_250_252(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 251), u => lookup_250_251(index), u => lookup_251_252(index))

def lookup_248_252(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 250), u => lookup_248_250(index), u => lookup_250_252(index))

def lookup_252_253(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1611133856, 3197921777}, 4294967294}, Fixed.Fixed{Core.Wide{2001583772, 326781417}, 4294967295}, Core.Wide{7507891, 4128208737}}

def lookup_253_254(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1441981665, 284017590}, 4294967294}, Fixed.Fixed{Core.Wide{2029799296, 2680279498}, 4294967295}, Core.Wide{7150247, 3589016112}}

def lookup_252_254(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 253), u => lookup_252_253(index), u => lookup_253_254(index))

def lookup_254_255(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1229110512, 2976848114}, 4294967294}, Fixed.Fixed{Core.Wide{2061324653, 2997111285}, 4294967295}, Core.Wide{6309364, 3353228722}}

def lookup_255_256(index: U32) -> Strip:
	Strip{Fixed.Fixed{Core.Wide{1848913807, 4158392567}, 4294967293}, Fixed.Fixed{Core.Wide{2098309925, 3888254765}, 4294967295}, Core.Wide{0, 0}}

def lookup_254_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 255), u => lookup_254_255(index), u => lookup_255_256(index))

def lookup_252_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 254), u => lookup_252_254(index), u => lookup_254_256(index))

def lookup_248_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 252), u => lookup_248_252(index), u => lookup_252_256(index))

def lookup_240_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 248), u => lookup_240_248(index), u => lookup_248_256(index))

def lookup_224_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 240), u => lookup_224_240(index), u => lookup_240_256(index))

def lookup_192_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 224), u => lookup_192_224(index), u => lookup_224_256(index))

def lookup_128_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 192), u => lookup_128_192(index), u => lookup_192_256(index))

def lookup_0_256(+index: U32) -> Strip:
	Fixed.branch(Strip, U32.is_lt(index, 128), u => lookup_0_128(index), u => lookup_128_256(index))

def lookup(index: U32) -> Strip:
	lookup_0_256(index)
