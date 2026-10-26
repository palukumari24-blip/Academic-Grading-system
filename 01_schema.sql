-- =====================================================================
--  ACADEMIC GRADING & STUDENT PERFORMANCE TRACKING SYSTEM
--  File   : 01_schema.sql
--  Purpose: Creates the database, tables, constraints and indexes.
--  Target : MySQL 8.0+ (also verified on MariaDB 10.11)
-- =====================================================================

DROP DATABASE IF EXISTS academic_db;
CREATE DATABASE academic_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
USE academic_db;

-- 1. DEPARTMENTS
CREATE TABLE departments (
    dept_id     TINYINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    dept_code   CHAR(3)           NOT NULL,
    dept_name   VARCHAR(80)       NOT NULL,
    CONSTRAINT pk_departments PRIMARY KEY (dept_id),
    CONSTRAINT uq_dept_code   UNIQUE (dept_code),
    CONSTRAINT uq_dept_name   UNIQUE (dept_name)
) ENGINE=InnoDB;

-- 2. STUDENTS (profile)
CREATE TABLE students (
    student_id       INT UNSIGNED     NOT NULL AUTO_INCREMENT,
    first_name       VARCHAR(40)      NOT NULL,
    last_name        VARCHAR(40)      NOT NULL,
    email            VARCHAR(120)     NOT NULL,
    gender           ENUM('M','F','O') NOT NULL,
    date_of_birth    DATE             NOT NULL,
    enrollment_date  DATE             NOT NULL,
    dept_id          TINYINT UNSIGNED NOT NULL,
    status           ENUM('Active','Graduated','Suspended','Withdrawn')
                                      NOT NULL DEFAULT 'Active',
    CONSTRAINT pk_students   PRIMARY KEY (student_id),
    CONSTRAINT uq_stu_email  UNIQUE (email),
    CONSTRAINT fk_stu_dept   FOREIGN KEY (dept_id) REFERENCES departments(dept_id),
    CONSTRAINT ck_stu_dates  CHECK (enrollment_date > date_of_birth)
) ENGINE=InnoDB;
CREATE INDEX ix_students_dept ON students (dept_id);

-- 3. INSTRUCTORS
CREATE TABLE instructors (
    instructor_id  SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name      VARCHAR(80)       NOT NULL,
    email          VARCHAR(120)      NOT NULL,
    dept_id        TINYINT UNSIGNED  NOT NULL,
    CONSTRAINT pk_instructors PRIMARY KEY (instructor_id),
    CONSTRAINT uq_ins_email   UNIQUE (email),
    CONSTRAINT fk_ins_dept    FOREIGN KEY (dept_id) REFERENCES departments(dept_id)
) ENGINE=InnoDB;

-- 4. COURSES (catalogue; credits live here)
CREATE TABLE courses (
    course_id     SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    course_code   VARCHAR(10)       NOT NULL,
    course_title  VARCHAR(100)      NOT NULL,
    credits       TINYINT UNSIGNED  NOT NULL,
    dept_id       TINYINT UNSIGNED  NOT NULL,
    CONSTRAINT pk_courses   PRIMARY KEY (course_id),
    CONSTRAINT uq_course_cd UNIQUE (course_code),
    CONSTRAINT fk_crs_dept  FOREIGN KEY (dept_id) REFERENCES departments(dept_id),
    CONSTRAINT ck_crs_cr    CHECK (credits BETWEEN 1 AND 6)
) ENGINE=InnoDB;

-- 5. SEMESTERS
CREATE TABLE semesters (
    semester_id  TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    term_name    VARCHAR(20)      NOT NULL,
    start_date   DATE             NOT NULL,
    end_date     DATE             NOT NULL,
    CONSTRAINT pk_semesters PRIMARY KEY (semester_id),
    CONSTRAINT uq_term      UNIQUE (term_name),
    CONSTRAINT ck_sem_dates CHECK (end_date > start_date)
) ENGINE=InnoDB;

-- 6. COURSE OFFERINGS (course taught in a semester by an instructor)
CREATE TABLE course_offerings (
    offering_id    INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    course_id      SMALLINT UNSIGNED NOT NULL,
    semester_id    TINYINT UNSIGNED  NOT NULL,
    instructor_id  SMALLINT UNSIGNED NOT NULL,
    CONSTRAINT pk_offerings  PRIMARY KEY (offering_id),
    CONSTRAINT uq_offering   UNIQUE (course_id, semester_id),
    CONSTRAINT fk_off_course FOREIGN KEY (course_id)     REFERENCES courses(course_id),
    CONSTRAINT fk_off_sem    FOREIGN KEY (semester_id)   REFERENCES semesters(semester_id),
    CONSTRAINT fk_off_ins    FOREIGN KEY (instructor_id) REFERENCES instructors(instructor_id)
) ENGINE=InnoDB;

-- 7. REGISTRATIONS (student enrolled in an offering)
CREATE TABLE registrations (
    registration_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    student_id       INT UNSIGNED NOT NULL,
    offering_id      INT UNSIGNED NOT NULL,
    registered_on    DATE         NOT NULL,
    status           ENUM('Registered','Completed','Withdrawn')
                                  NOT NULL DEFAULT 'Registered',
    CONSTRAINT pk_registrations PRIMARY KEY (registration_id),
    CONSTRAINT uq_reg           UNIQUE (student_id, offering_id),
    CONSTRAINT fk_reg_student   FOREIGN KEY (student_id)  REFERENCES students(student_id),
    CONSTRAINT fk_reg_offering  FOREIGN KEY (offering_id) REFERENCES course_offerings(offering_id)
) ENGINE=InnoDB;
CREATE INDEX ix_reg_offering ON registrations (offering_id);

-- 8. ASSESSMENT WEIGHTS (how each exam type counts toward course %)
CREATE TABLE assessment_weights (
    assessment_type  ENUM('Assignment','Midterm','Final') NOT NULL,
    weight_pct       DECIMAL(5,2)                         NOT NULL,
    CONSTRAINT pk_weights PRIMARY KEY (assessment_type),
    CONSTRAINT ck_weight  CHECK (weight_pct > 0 AND weight_pct <= 100)
) ENGINE=InnoDB;

-- 9. EXAM GRADES (raw marks per registration per assessment)
CREATE TABLE exam_grades (
    grade_id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    registration_id  INT UNSIGNED  NOT NULL,
    assessment_type  ENUM('Assignment','Midterm','Final') NOT NULL,
    score            DECIMAL(5,2)  NOT NULL,
    max_score        DECIMAL(5,2)  NOT NULL DEFAULT 100.00,
    graded_on        DATE          NOT NULL,
    CONSTRAINT pk_exam_grades PRIMARY KEY (grade_id),
    CONSTRAINT uq_exam        UNIQUE (registration_id, assessment_type),
    CONSTRAINT fk_gr_reg      FOREIGN KEY (registration_id) REFERENCES registrations(registration_id),
    CONSTRAINT fk_gr_weight   FOREIGN KEY (assessment_type) REFERENCES assessment_weights(assessment_type),
    CONSTRAINT ck_score       CHECK (score >= 0 AND score <= max_score AND max_score > 0)
) ENGINE=InnoDB;

-- 10. GRADE SCALE (percentage band -> letter -> grade points)
CREATE TABLE grade_scale (
    letter_grade  VARCHAR(2)    NOT NULL,
    min_pct       DECIMAL(5,2)  NOT NULL,
    max_pct       DECIMAL(5,2)  NOT NULL,
    grade_points  DECIMAL(3,2)  NOT NULL,
    is_pass       TINYINT(1)    NOT NULL,
    CONSTRAINT pk_grade_scale PRIMARY KEY (letter_grade),
    CONSTRAINT ck_band        CHECK (max_pct >= min_pct)
) ENGINE=InnoDB;

-- 11. ACADEMIC POLICY (single source of truth for thresholds)
CREATE TABLE academic_policy (
    policy_key    VARCHAR(40)   NOT NULL,
    policy_value  DECIMAL(5,2)  NOT NULL,
    description   VARCHAR(200)  NOT NULL,
    CONSTRAINT pk_policy PRIMARY KEY (policy_key)
) ENGINE=InnoDB;

-- 12. PROBATION LOG (audit trail written by sp_refresh_probation)
CREATE TABLE probation_log (
    log_id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    student_id    INT UNSIGNED NOT NULL,
    semester_id   TINYINT UNSIGNED NOT NULL,
    cgpa          DECIMAL(4,2) NOT NULL,
    sgpa          DECIMAL(4,2) NOT NULL,
    risk_level    ENUM('Probation','At Risk','Watch') NOT NULL,
    reason        VARCHAR(200) NOT NULL,
    flagged_on    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_probation_log PRIMARY KEY (log_id),
    CONSTRAINT uq_prob UNIQUE (student_id, semester_id),
    CONSTRAINT fk_pl_student FOREIGN KEY (student_id)  REFERENCES students(student_id),
    CONSTRAINT fk_pl_sem     FOREIGN KEY (semester_id) REFERENCES semesters(semester_id)
) ENGINE=InnoDB;
