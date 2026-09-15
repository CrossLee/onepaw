using Xunit;

namespace Crosio.Windows.Sharing.Tests;

public sealed class ShareAccessCodeTests
{
    [Theory]
    [InlineData("abc123", "abc123")]
    [InlineData("  Class-2026_A  ", "Class-2026_A")]
    [InlineData("123456789012345678901234", "123456789012345678901234")]
    public void ValidCustomCodesAreNormalized(string input, string expected)
    {
        Assert.Equal(expected, ShareAccessCode.NormalizeCustom(input));
    }

    [Theory]
    [InlineData("")]
    [InlineData("12345")]
    [InlineData("1234567890123456789012345")]
    [InlineData("课堂2026")]
    [InlineData("abc?123")]
    [InlineData("abc&123")]
    [InlineData("abc#123")]
    [InlineData("abc 123")]
    public void UnsafeCustomCodesAreRejected(string input)
    {
        Assert.Throws<ArgumentException>(() => ShareAccessCode.NormalizeCustom(input));
    }

    [Fact]
    public void DefaultRandomCodeIsShortReadableAndNotConstant()
    {
        var codes = Enumerable.Range(0, 32).Select(_ => ShareAccessCode.CreateRandom()).ToArray();

        Assert.All(codes, code =>
        {
            Assert.Equal(ShareAccessCode.DefaultRandomLength, code.Length);
            Assert.True(ShareAccessCode.TryNormalizeCustom(code, out var normalized));
            Assert.Equal(code, normalized);
            Assert.DoesNotContain('0', code);
            Assert.DoesNotContain('1', code);
        });
        Assert.True(codes.Distinct(StringComparer.Ordinal).Count() > 1);
    }
}
