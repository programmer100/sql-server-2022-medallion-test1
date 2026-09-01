using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Text;

namespace SqlServerMedallion.Bronze
{
    public sealed class CsvReject
    {
        public long SourceRecordNumber { get; set; }
        public string Reason { get; set; }
        public string RawFragment { get; set; }
    }

    internal sealed class ParsedCsvRecord
    {
        public string[] Fields { get; set; }
        public string Raw { get; set; }
    }

    public sealed class CsvDataReader : IDataReader
    {
        private const int TechnicalColumnCount = 5;
        private readonly TextReader _reader;
        private readonly char _delimiter;
        private readonly char _quote;
        private readonly bool _treatEmptyAsNull;
        private readonly string[] _sourceColumns;
        private readonly string[] _targetColumns;
        private readonly int[] _sourceOrdinals;
        private readonly int[] _landingMaxLengths;
        private readonly long _fileLoadId;
        private readonly long _fileLoadAttemptId;
        private readonly string _sourceFileName;
        private readonly DateTime _ingestedAtUtc;
        private readonly string[] _header;
        private string[] _current;
        private long _currentSourceRecordNumber;
        private long _nextSourceRecordNumber;
        private bool _closed;
        private bool _endOfStream;

        public CsvDataReader(
            TextReader reader,
            char delimiter,
            char quote,
            bool treatEmptyAsNull,
            string[] sourceColumns,
            string[] targetColumns,
            bool[] optionalColumns,
            int[] landingMaxLengths,
            long fileLoadId,
            long fileLoadAttemptId,
            string sourceFileName,
            DateTime ingestedAtUtc)
        {
            if (reader == null) throw new ArgumentNullException("reader");
            if (sourceColumns == null) throw new ArgumentNullException("sourceColumns");
            if (targetColumns == null) throw new ArgumentNullException("targetColumns");
            if (optionalColumns == null) throw new ArgumentNullException("optionalColumns");
            if (landingMaxLengths == null) throw new ArgumentNullException("landingMaxLengths");
            if (sourceColumns.Length == 0) throw new ArgumentException("At least one mapped column is required.");
            if (sourceColumns.Length != targetColumns.Length
                || sourceColumns.Length != optionalColumns.Length
                || sourceColumns.Length != landingMaxLengths.Length)
            {
                throw new ArgumentException("CSV mapping arrays must have matching lengths.");
            }

            _reader = reader;
            _delimiter = delimiter;
            _quote = quote;
            _treatEmptyAsNull = treatEmptyAsNull;
            _sourceColumns = sourceColumns;
            _targetColumns = targetColumns;
            _landingMaxLengths = landingMaxLengths;
            _fileLoadId = fileLoadId;
            _fileLoadAttemptId = fileLoadAttemptId;
            _sourceFileName = sourceFileName;
            _ingestedAtUtc = DateTime.SpecifyKind(ingestedAtUtc, DateTimeKind.Utc);
            _sourceOrdinals = new int[sourceColumns.Length];
            Rejects = new List<CsvReject>();
            MaxRejects = 100;
            MaxRecordCharacters = 16 * 1024 * 1024;
            MaxRawFragmentCharacters = 4000;

            ParsedCsvRecord headerRecord = ReadRecord();
            if (headerRecord == null)
            {
                throw new InvalidDataException("CSV file contains no header record.");
            }

            _nextSourceRecordNumber = 1;
            _header = headerRecord.Fields;
            var headerLookup = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int index = 0; index < _header.Length; index++)
            {
                string name = (_header[index] ?? string.Empty).Trim().TrimStart('\uFEFF');
                if (name.Length == 0)
                {
                    throw new InvalidDataException("CSV header contains an empty column name at ordinal " + (index + 1) + ".");
                }
                if (headerLookup.ContainsKey(name))
                {
                    throw new InvalidDataException("CSV header contains duplicate column name '" + name + "'.");
                }
                _header[index] = name;
                headerLookup.Add(name, index);
            }

            for (int index = 0; index < sourceColumns.Length; index++)
            {
                int sourceOrdinal;
                if (!headerLookup.TryGetValue(sourceColumns[index], out sourceOrdinal))
                {
                    if (!optionalColumns[index])
                    {
                        throw new InvalidDataException("CSV header is missing required column '" + sourceColumns[index] + "'.");
                    }
                    sourceOrdinal = -1;
                }
                _sourceOrdinals[index] = sourceOrdinal;
            }
        }

        public string[] Header { get { return (string[])_header.Clone(); } }
        public long RowsParsed { get; private set; }
        public long RowsAccepted { get; private set; }
        public long RowsRejected { get; private set; }
        public int MaxRejects { get; set; }
        public int MaxRecordCharacters { get; set; }
        public int MaxRawFragmentCharacters { get; set; }
        public bool CaptureRejectFragments { get; set; }
        public List<CsvReject> Rejects { get; private set; }

        private ParsedCsvRecord ReadRecord()
        {
            if (_endOfStream) return null;

            var fields = new List<string>();
            var field = new StringBuilder();
            var raw = new StringBuilder();
            bool inQuotes = false;
            bool afterClosingQuote = false;
            bool atFieldStart = true;
            bool sawAnyCharacter = false;

            while (true)
            {
                int next = _reader.Read();
                if (next == -1)
                {
                    _endOfStream = true;
                    if (!sawAnyCharacter && fields.Count == 0 && field.Length == 0)
                    {
                        return null;
                    }
                    if (inQuotes)
                    {
                        throw new InvalidDataException("CSV contains an unterminated quoted field at source record " + (_nextSourceRecordNumber + 1) + ".");
                    }
                    fields.Add(field.ToString());
                    return new ParsedCsvRecord { Fields = fields.ToArray(), Raw = raw.ToString() };
                }

                sawAnyCharacter = true;
                char current = (char)next;
                raw.Append(current);
                if (raw.Length > MaxRecordCharacters)
                {
                    throw new InvalidDataException("CSV source record " + (_nextSourceRecordNumber + 1) + " exceeds MaxRecordCharacters.");
                }

                if (inQuotes)
                {
                    if (current == _quote)
                    {
                        if (_reader.Peek() == _quote)
                        {
                            int escapedQuote = _reader.Read();
                            raw.Append((char)escapedQuote);
                            field.Append(_quote);
                        }
                        else
                        {
                            inQuotes = false;
                            afterClosingQuote = true;
                        }
                    }
                    else
                    {
                        field.Append(current);
                    }
                    continue;
                }

                if (afterClosingQuote)
                {
                    if (current == _delimiter)
                    {
                        fields.Add(field.ToString());
                        field.Clear();
                        afterClosingQuote = false;
                        atFieldStart = true;
                        continue;
                    }
                    if (current == '\r' || current == '\n')
                    {
                        if (current == '\r' && _reader.Peek() == '\n')
                        {
                            raw.Append((char)_reader.Read());
                        }
                        fields.Add(field.ToString());
                        return new ParsedCsvRecord { Fields = fields.ToArray(), Raw = raw.ToString() };
                    }
                    throw new InvalidDataException("CSV source record " + (_nextSourceRecordNumber + 1) + " contains a character after a closing quote.");
                }

                if (current == _quote)
                {
                    if (!atFieldStart)
                    {
                        throw new InvalidDataException("CSV source record " + (_nextSourceRecordNumber + 1) + " contains a quote inside an unquoted field.");
                    }
                    inQuotes = true;
                    atFieldStart = false;
                }
                else if (current == _delimiter)
                {
                    fields.Add(field.ToString());
                    field.Clear();
                    atFieldStart = true;
                }
                else if (current == '\r' || current == '\n')
                {
                    if (current == '\r' && _reader.Peek() == '\n')
                    {
                        raw.Append((char)_reader.Read());
                    }
                    fields.Add(field.ToString());
                    return new ParsedCsvRecord { Fields = fields.ToArray(), Raw = raw.ToString() };
                }
                else
                {
                    field.Append(current);
                    atFieldStart = false;
                }
            }
        }

        private void Reject(long sourceRecordNumber, string reason, string raw)
        {
            RowsRejected++;
            if (Rejects.Count < MaxRejects)
            {
                string fragment = null;
                if (CaptureRejectFragments && raw != null)
                {
                    fragment = raw.Length <= MaxRawFragmentCharacters
                        ? raw
                        : raw.Substring(0, MaxRawFragmentCharacters);
                }
                Rejects.Add(new CsvReject
                {
                    SourceRecordNumber = sourceRecordNumber,
                    Reason = reason,
                    RawFragment = fragment
                });
            }
            if (RowsRejected > MaxRejects)
            {
                throw new InvalidDataException("CSV rejected-record threshold of " + MaxRejects + " was exceeded.");
            }
        }

        public bool Read()
        {
            while (true)
            {
                ParsedCsvRecord record = ReadRecord();
                if (record == null)
                {
                    _current = null;
                    return false;
                }

                _nextSourceRecordNumber++;
                _currentSourceRecordNumber = _nextSourceRecordNumber;
                RowsParsed++;

                if (record.Fields.Length != _header.Length)
                {
                    Reject(
                        _currentSourceRecordNumber,
                        "Field count " + record.Fields.Length + " does not match header count " + _header.Length + ".",
                        record.Raw);
                    continue;
                }

                string lengthError = null;
                for (int index = 0; index < _sourceOrdinals.Length; index++)
                {
                    int sourceOrdinal = _sourceOrdinals[index];
                    if (sourceOrdinal >= 0
                        && _landingMaxLengths[index] > 0
                        && record.Fields[sourceOrdinal].Length > _landingMaxLengths[index])
                    {
                        lengthError = "Column '" + _sourceColumns[index] + "' exceeds landingMaxLength " + _landingMaxLengths[index] + ".";
                        break;
                    }
                }
                if (lengthError != null)
                {
                    Reject(_currentSourceRecordNumber, lengthError, record.Raw);
                    continue;
                }

                _current = record.Fields;
                RowsAccepted++;
                return true;
            }
        }

        public int FieldCount { get { return _targetColumns.Length + TechnicalColumnCount; } }

        public string GetName(int index)
        {
            if (index < 0 || index >= FieldCount) throw new IndexOutOfRangeException();
            if (index < _targetColumns.Length) return _targetColumns[index];
            switch (index - _targetColumns.Length)
            {
                case 0: return "FileLoadId";
                case 1: return "FileLoadAttemptId";
                case 2: return "SourceRecordNumber";
                case 3: return "SourceFileName";
                case 4: return "IngestedAtUtc";
                default: throw new IndexOutOfRangeException();
            }
        }

        public int GetOrdinal(string name)
        {
            for (int index = 0; index < FieldCount; index++)
            {
                if (string.Equals(GetName(index), name, StringComparison.OrdinalIgnoreCase)) return index;
            }
            throw new IndexOutOfRangeException("Column not found: " + name);
        }

        public object GetValue(int index)
        {
            if (index < 0 || index >= FieldCount) throw new IndexOutOfRangeException();
            if (index < _targetColumns.Length)
            {
                int sourceOrdinal = _sourceOrdinals[index];
                if (sourceOrdinal < 0) return DBNull.Value;
                string value = _current[sourceOrdinal];
                return _treatEmptyAsNull && value.Length == 0 ? (object)DBNull.Value : value;
            }
            switch (index - _targetColumns.Length)
            {
                case 0: return _fileLoadId;
                case 1: return _fileLoadAttemptId;
                case 2: return _currentSourceRecordNumber;
                case 3: return _sourceFileName;
                case 4: return _ingestedAtUtc;
                default: throw new IndexOutOfRangeException();
            }
        }

        public Type GetFieldType(int index)
        {
            if (index < _targetColumns.Length) return typeof(string);
            switch (index - _targetColumns.Length)
            {
                case 0:
                case 1:
                case 2:
                    return typeof(long);
                case 3:
                    return typeof(string);
                case 4:
                    return typeof(DateTime);
                default:
                    throw new IndexOutOfRangeException();
            }
        }

        public bool IsDBNull(int index) { return GetValue(index) == DBNull.Value; }
        public int GetValues(object[] values)
        {
            int count = Math.Min(values.Length, FieldCount);
            for (int index = 0; index < count; index++) values[index] = GetValue(index);
            return count;
        }

        public object this[int index] { get { return GetValue(index); } }
        public object this[string name] { get { return GetValue(GetOrdinal(name)); } }
        public bool IsClosed { get { return _closed; } }
        public int Depth { get { return 0; } }
        public int RecordsAffected { get { return -1; } }
        public void Close() { if (!_closed) { _closed = true; _reader.Dispose(); } }
        public void Dispose() { Close(); }
        public bool NextResult() { return false; }
        public DataTable GetSchemaTable() { return null; }
        public string GetDataTypeName(int index) { return GetFieldType(index).Name; }
        public bool GetBoolean(int index) { return Convert.ToBoolean(GetValue(index)); }
        public byte GetByte(int index) { return Convert.ToByte(GetValue(index)); }
        public long GetBytes(int index, long fieldOffset, byte[] buffer, int bufferOffset, int length) { throw new NotSupportedException(); }
        public char GetChar(int index) { return Convert.ToChar(GetValue(index)); }
        public long GetChars(int index, long fieldOffset, char[] buffer, int bufferOffset, int length) { throw new NotSupportedException(); }
        public IDataReader GetData(int index) { throw new NotSupportedException(); }
        public DateTime GetDateTime(int index) { return Convert.ToDateTime(GetValue(index)); }
        public decimal GetDecimal(int index) { return Convert.ToDecimal(GetValue(index)); }
        public double GetDouble(int index) { return Convert.ToDouble(GetValue(index)); }
        public float GetFloat(int index) { return Convert.ToSingle(GetValue(index)); }
        public Guid GetGuid(int index) { return Guid.Parse(GetString(index)); }
        public short GetInt16(int index) { return Convert.ToInt16(GetValue(index)); }
        public int GetInt32(int index) { return Convert.ToInt32(GetValue(index)); }
        public long GetInt64(int index) { return Convert.ToInt64(GetValue(index)); }
        public string GetString(int index) { return Convert.ToString(GetValue(index)); }
    }
}
