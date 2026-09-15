using System.Security.Cryptography;

namespace Crosio.Windows.Sharing;

public static class ShareAccessCode
{
    public const int MinimumLength = 6;
    public const int MaximumLength = 24;
    public const int DefaultRandomLength = 10;

    private const string RandomAlphabet = "23456789abcdefghjkmnpqrstuvwxyz";

    public static string NormalizeCustom(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var normalized = value.Trim();
        if (normalized.Length is < MinimumLength or > MaximumLength)
        {
            throw new ArgumentException($"共享访问码必须为 {MinimumLength}–{MaximumLength} 位。", nameof(value));
        }

        foreach (var character in normalized)
        {
            var allowed = character is >= 'a' and <= 'z'
                or >= 'A' and <= 'Z'
                or >= '0' and <= '9'
                or '-' or '_';
            if (!allowed)
            {
                throw new ArgumentException("共享访问码只能包含英文字母、数字、- 和 _。", nameof(value));
            }
        }

        return normalized;
    }

    public static bool TryNormalizeCustom(string? value, out string normalized)
    {
        try
        {
            normalized = NormalizeCustom(value ?? string.Empty);
            return true;
        }
        catch (ArgumentException)
        {
            normalized = string.Empty;
            return false;
        }
    }

    public static string CreateRandom(int length = DefaultRandomLength)
    {
        if (length is < MinimumLength or > MaximumLength)
        {
            throw new ArgumentOutOfRangeException(nameof(length));
        }

        return string.Create(length, RandomAlphabet, static (buffer, alphabet) =>
        {
            for (var index = 0; index < buffer.Length; index++)
            {
                buffer[index] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
            }
        });
    }
}
