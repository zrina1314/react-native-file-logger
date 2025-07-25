package com.betomorrow.rnfilelogger;

import android.content.Intent;
import android.net.Uri;

import androidx.core.content.FileProvider;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.WritableArray;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.FilenameFilter;
import java.io.FileOutputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.LoggerContext;
import ch.qos.logback.classic.encoder.PatternLayoutEncoder;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.Appender;
import ch.qos.logback.core.rolling.FixedWindowRollingPolicy;
import ch.qos.logback.core.rolling.RollingFileAppender;
import ch.qos.logback.core.rolling.SizeAndTimeBasedRollingPolicy;
import ch.qos.logback.core.rolling.SizeBasedTriggeringPolicy;
import ch.qos.logback.core.util.FileSize;

public class FileLoggerModule extends FileLoggerSpec {
    public static final String NAME = "FileLogger";
    public static final String APPENDER_NAME = "FileLoggerAppender";
    private static final int LOG_LEVEL_DEBUG = 0;
    private static final int LOG_LEVEL_INFO = 1;
    private static final int LOG_LEVEL_WARNING = 2;
    private static final int LOG_LEVEL_ERROR = 3;

    private static Logger logger = LoggerFactory.getLogger(FileLoggerModule.class);

    private final ReactApplicationContext reactContext;
    private String logsDirectory;
    private ReadableMap configureOptions;

    public FileLoggerModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
    }

    public String getName() {
        return NAME;
    }

    @ReactMethod
    public void configure(ReadableMap options, Promise promise) {
        boolean dailyRolling = options.getBoolean("dailyRolling");
        int maximumFileSize = options.getInt("maximumFileSize");
        int maximumNumberOfFiles = options.getInt("maximumNumberOfFiles");
       

        logsDirectory = options.hasKey("logsDirectory")
                ? options.getString("logsDirectory")
                : reactContext.getExternalCacheDir() + "/logs";
        String logPrefix = options.hasKey("logPrefix")
                ? options.getString("logPrefix")
                :reactContext.getPackageName();
        

        configureLogger(dailyRolling, maximumFileSize, maximumNumberOfFiles, logsDirectory, logPrefix);

        configureOptions = options;
        promise.resolve(null);
    }

    public static void configureLogger(boolean dailyRolling, int maximumFileSize, int maximumNumberOfFiles, String logsDirectory, String logPrefix) {
        LoggerContext loggerContext = (LoggerContext) LoggerFactory.getILoggerFactory();

        RollingFileAppender<ILoggingEvent> rollingFileAppender = new RollingFileAppender<>();
        rollingFileAppender.setContext(loggerContext);
        rollingFileAppender.setName(APPENDER_NAME);
        rollingFileAppender.setFile(logsDirectory + "/" + logPrefix + "-latest.log");

        if (dailyRolling) {
            SizeAndTimeBasedRollingPolicy<ILoggingEvent> rollingPolicy = new SizeAndTimeBasedRollingPolicy<>();
            rollingPolicy.setContext(loggerContext);
            rollingPolicy.setFileNamePattern(logsDirectory + "/" + logPrefix + "-%d{yyyy-MM-dd}.%i.log");
            rollingPolicy.setMaxFileSize(new FileSize(maximumFileSize));
            rollingPolicy.setTotalSizeCap(new FileSize(maximumNumberOfFiles * maximumFileSize));
            rollingPolicy.setMaxHistory(maximumNumberOfFiles);
            rollingPolicy.setParent(rollingFileAppender);
            rollingPolicy.start();
            rollingFileAppender.setRollingPolicy(rollingPolicy);

        } else if (maximumFileSize > 0) {
            FixedWindowRollingPolicy rollingPolicy = new FixedWindowRollingPolicy();
            rollingPolicy.setContext(loggerContext);
            rollingPolicy.setFileNamePattern(logsDirectory + "/" + logPrefix + "-%i.log");
            rollingPolicy.setMinIndex(1);
            rollingPolicy.setMaxIndex(maximumNumberOfFiles);
            rollingPolicy.setParent(rollingFileAppender);
            rollingPolicy.start();
            rollingFileAppender.setRollingPolicy(rollingPolicy);

            SizeBasedTriggeringPolicy triggeringPolicy = new SizeBasedTriggeringPolicy();
            triggeringPolicy.setContext(loggerContext);
            triggeringPolicy.setMaxFileSize(new FileSize(maximumFileSize));
            triggeringPolicy.start();
            rollingFileAppender.setTriggeringPolicy(triggeringPolicy);
        }

        PatternLayoutEncoder encoder = new PatternLayoutEncoder();
        encoder.setContext(loggerContext);
        encoder.setCharset(Charset.forName("UTF-8"));
        encoder.setPattern("%msg%n");
        encoder.start();

        rollingFileAppender.setEncoder(encoder);
        rollingFileAppender.start();

        renewAppender(rollingFileAppender);
    }

    private static void renewAppender(Appender appender) {
        ch.qos.logback.classic.Logger root = (ch.qos.logback.classic.Logger) LoggerFactory.getLogger(Logger.ROOT_LOGGER_NAME);
        root.setLevel(Level.DEBUG);
        // Stopping the previous appender to release any resources it might be holding (file handles) and to ensure a clean shutdown.
        Appender previousFileLoggerAppender = root.getAppender(APPENDER_NAME);
        if (previousFileLoggerAppender != null) {
            previousFileLoggerAppender.stop();
            root.detachAppender(APPENDER_NAME);
        }
        root.addAppender(appender);
    }

    @ReactMethod
    public void write(double level, String str) {
        switch ((int) level) {
            case LOG_LEVEL_DEBUG:
                logger.debug(str);
                break;
            case LOG_LEVEL_INFO:
                logger.info(str);
                break;
            case LOG_LEVEL_WARNING:
                logger.warn(str);
                break;
            case LOG_LEVEL_ERROR:
                logger.error(str);
                break;
        }
    }

    @ReactMethod
    public void getLogFilePaths(Promise promise) {
        try {
            WritableArray result = Arguments.createArray();
            for (File logFile: getLogFiles()) {
                result.pushString(logFile.getAbsolutePath());
            }
            promise.resolve(result);
        } catch (Exception e) {
            promise.reject(e);
        }
    }

    @ReactMethod
    public void deleteLogFiles(Promise promise) {
        try {
            for (File file: getLogFiles()) {
                file.delete();
            }
            if (configureOptions != null) {
                configure(configureOptions, promise);
            } else {
                promise.resolve(null);
            }
        } catch (Exception e) {
            promise.reject(e);
        }
    }

    @ReactMethod
    public void sendLogFilesByEmail(ReadableMap options, Promise promise) {
        try {
            ReadableArray to = options.hasKey("to") ? options.getArray("to") : null;
            String subject = options.hasKey("subject") ? options.getString("subject") : null;
            String body = options.hasKey("body") ? options.getString("body") : null;
            boolean compressFiles = options.hasKey("compressFiles") && options.getBoolean("compressFiles");

            Intent intent = new Intent(Intent.ACTION_SEND_MULTIPLE, Uri.parse("mailto:"));
            intent.setType("plain/text");
            
            if (to != null) {
                intent.putExtra(Intent.EXTRA_EMAIL, readableArrayToStringArray(to));
            }
            if (subject != null) {
                intent.putExtra(Intent.EXTRA_SUBJECT, subject);
            }
            if (body != null) {
                intent.putExtra(Intent.EXTRA_TEXT, body);
            }

            ArrayList<Uri> uris = new ArrayList<>();
            File[] logFiles = getLogFiles();

            if (compressFiles && logFiles.length > 0) {
                // Create a zip file containing all log files
                File zipFile = new File(logsDirectory, "logs.zip");
                try (FileOutputStream fos = new FileOutputStream(zipFile);
                     ZipOutputStream zos = new ZipOutputStream(fos)) {
                    
                    for (File logFile : logFiles) {
                        ZipEntry zipEntry = new ZipEntry(logFile.getName());
                        zos.putNextEntry(zipEntry);
                        java.nio.file.Files.copy(logFile.toPath(), zos);
                        zos.closeEntry();
                    }
                }

                Uri zipUri = FileProvider.getUriForFile(
                    reactContext,
                    reactContext.getApplicationContext().getPackageName() + ".provider",
                    zipFile);
                uris.add(zipUri);
            } else {
                // Send individual log files
                for (File file : logFiles) {
                    Uri fileUri = FileProvider.getUriForFile(
                        reactContext,
                        reactContext.getApplicationContext().getPackageName() + ".provider",
                        file);
                    uris.add(fileUri);
                }
            }

            intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            
            reactContext.startActivity(intent);

            promise.resolve(null);
        } catch (Exception e) {
            promise.reject(e);
        }
    }

    private File[] getLogFiles() {
        File directory = new File(logsDirectory);
        return directory.listFiles(new FilenameFilter() {
            @Override
            public boolean accept(File dir, String name) {
                return name.endsWith(".log");
            }
        });
    }

    private String[] readableArrayToStringArray(ReadableArray r) {
        int length = r.size();
        String[] strArray = new String[length];
        for (int i = 0; i < length; i++) {
            strArray[i] = r.getString(i);
        }
        return strArray;
  }

}
