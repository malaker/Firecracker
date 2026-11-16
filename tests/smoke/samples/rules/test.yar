rule fc_test_sample
{
    strings:
        $marker = "FC-TEST-SAMPLE"
    condition:
        $marker
}
